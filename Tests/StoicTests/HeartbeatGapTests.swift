@testable import Stoic
import StoicTesting
import Synchronization
import Testing

/// A clock that moves in one jump, the way a suspended process sees the
/// suspending clock: nothing runs while the time passes (`kill -STOP`, an iOS
/// app suspended in the background), and every sleeper that came due wakes
/// afterwards to find the clock already at the end. A `TestClock` cannot show
/// this: it wakes each sleeper with the clock at that sleeper's deadline.
final class JumpClock: Clock, Sendable {
    typealias Duration = Swift.Duration
    typealias Instant = TestClock.Instant

    private struct Sleeper {
        let deadline: Swift.Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: Swift.Duration = .zero
        var nextID: UInt64 = 0
        var sleepers: [UInt64: Sleeper] = [:]
        var arriving: Set<UInt64> = []
        var cancelledBeforeSleeping: Set<UInt64> = []
    }

    private let state = Mutex(State())

    var now: Instant { Instant(offset: state.withLock { $0.now }) }
    var minimumResolution: Swift.Duration { .zero }
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Swift.Duration? = nil) async throws {
        try Task.checkCancellation()
        let id = state.withLock { state -> UInt64 in
            defer { state.nextID += 1 }
            state.arriving.insert(state.nextID)
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // nil: asleep; true: due already; false: cancelled first.
                let wake = state.withLock { state -> Bool? in
                    state.arriving.remove(id)
                    if state.cancelledBeforeSleeping.remove(id) != nil { return false }
                    if deadline.offset <= state.now { return true }
                    state.sleepers[id] = Sleeper(deadline: deadline.offset, continuation: continuation)
                    return nil
                }
                switch wake {
                case true?: continuation.resume()
                case false?: continuation.resume(throwing: CancellationError())
                case nil: break
                }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                if let sleeper = state.sleepers.removeValue(forKey: id) { return sleeper }
                if state.arriving.contains(id) { state.cancelledBeforeSleeping.insert(id) }
                return nil
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves the clock forward by `duration` at once, then wakes every
    /// sleeper that came due.
    func jump(by duration: Swift.Duration) {
        let due = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            state.now += duration
            let now = state.now
            let due = state.sleepers.filter { $0.value.deadline <= now }.sorted { $0.key < $1.key }
            for (id, _) in due { state.sleepers[id] = nil }
            return due.map(\.value.continuation)
        }
        for continuation in due { continuation.resume() }
    }
}

@Suite("Supervisor heartbeat gaps")
struct HeartbeatGapTests {
    /// Runs one supervised child with `policy` on a wall `TestClock` and a
    /// `JumpClock` for liveness. The child records its heartbeat and then
    /// waits, so only the test beats for it.
    final class Rig: Sendable {
        let wall = TestClock()
        let liveness = JumpClock()
        let events = RecordingInstrumentation()
        let starts = SendableBox(0)
        let heartbeat = SendableBox<Heartbeat?>(nil)
        let supervisor: Supervisor

        init(_ policy: HeartbeatPolicy) {
            let starts = starts, heartbeat = heartbeat
            supervisor = Supervisor(label: "gap", backoff: .immediate) {
                Child("tap", heartbeat: policy) { beat in
                    heartbeat.mutate { $0 = beat }
                    starts.mutate { $0 += 1 }
                    try await Task.sleep(for: .seconds(3600))
                }
            }
        }

        func run() -> Task<Void, Never> {
            Task {
                await withTestAmbient(clock: wall, events: events) {
                    await withAmbient({ $0.livenessClock = AnyClock(self.liveness, name: "jump") }) {
                        try? await self.supervisor.run()
                    }
                }
            }
        }

        /// Waits until the heartbeat monitor is asleep on the liveness clock.
        func monitorAsleep() async -> Bool {
            await eventually { liveness.sleeperCount == 1 }
        }

        func beat() { heartbeat.value?.beat() }

        var hung: Bool { events.names.contains("supervisor.child_hung") }
    }

    /// The process is suspended for twelve intervals while the child is
    /// healthy. On resume every overdue check would come due at once, back to
    /// back, before the child could run: counted as misses, they would declare
    /// it hung. A gap is not evidence, and the child gets a full interval.
    @Test(.timeLimit(.minutes(1)), .failureMode("design/09", "the process is suspended for longer than an interval"))
    func aSuspendedProcessDoesNotHangAHealthyChild() async {
        let rig = Rig(.init(interval: .seconds(5), misses: 3, grace: .zero))
        let run = rig.run()
        #expect(await eventually { rig.starts.value == 1 })
        #expect(await rig.monitorAsleep())
        rig.beat()

        rig.liveness.jump(by: .seconds(60))
        // Asleep again: on the next check, or (when hung) in a restarted child.
        #expect(await rig.monitorAsleep())
        #expect(rig.starts.value == 1, "a healthy child was restarted after a suspension")
        #expect(!rig.hung)

        // After the gap, the child that beats every interval is left alone…
        for _ in 0..<4 {
            rig.beat()
            rig.liveness.jump(by: .seconds(5))
            #expect(await rig.monitorAsleep())
        }
        #expect(rig.starts.value == 1)
        #expect(!rig.hung)

        // …and one that stops beating is hung after `misses` intervals.
        for _ in 0..<2 {
            rig.liveness.jump(by: .seconds(5))
            #expect(await rig.monitorAsleep())
            #expect(rig.starts.value == 1)
        }
        rig.liveness.jump(by: .seconds(5))
        #expect(await eventually { rig.starts.value == 2 })
        #expect(rig.hung)
        run.cancel()
        await run.value
    }

    /// A monitor woken late by less than an interval is judged on time, and
    /// its next check stays on the fixed instant: its own scheduling delays
    /// neither stretch the wait nor accumulate.
    @Test(.timeLimit(.minutes(1))) func aSlightlyLateCheckKeepsItsFixedInstants() async {
        let rig = Rig(.init(interval: .seconds(5), misses: 2, grace: .zero))
        let run = rig.run()
        #expect(await eventually { rig.starts.value == 1 })
        #expect(await rig.monitorAsleep())

        rig.liveness.jump(by: .seconds(7))   // the check due at 5 runs 2 s late: one miss
        #expect(await rig.monitorAsleep())
        #expect(rig.starts.value == 1)
        rig.liveness.jump(by: .seconds(3))   // the next is due at 10, not 12: the second miss
        #expect(await eventually { rig.starts.value == 2 })
        #expect(rig.hung)
        run.cancel()
        await run.value
    }

    /// Suspended during the grace period: the grace still ends, and the
    /// child still gets a full interval after the resume.
    @Test(.timeLimit(.minutes(1))) func aSuspensionDuringTheGracePeriodIsAGapToo() async {
        let rig = Rig(.init(interval: .seconds(5), misses: 1, grace: .seconds(10)))
        let run = rig.run()
        #expect(await eventually { rig.starts.value == 1 })
        #expect(await rig.monitorAsleep())

        rig.liveness.jump(by: .seconds(120))
        #expect(await rig.monitorAsleep())
        #expect(rig.starts.value == 1)
        rig.beat()
        rig.liveness.jump(by: .seconds(5))
        #expect(await rig.monitorAsleep())
        #expect(rig.starts.value == 1)
        #expect(!rig.hung)
        run.cancel()
        await run.value
    }
}
