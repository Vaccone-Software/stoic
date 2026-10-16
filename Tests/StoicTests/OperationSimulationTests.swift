@testable import Stoic
import StoicTesting
import Synchronization
import Testing

/// Many callers at mixed urgencies over a backend that slows and fails, in
/// a deterministic simulation across seeds (design/22, Testing).
@Suite("Operation simulation")
struct OperationSimulationTests {
    /// One call, as the simulation saw it.
    struct Call: Sendable {
        let urgency: Urgency
        let start: Duration
        let end: Duration
        let firstAttempt: Duration?
        let stop: String?
    }

    @Test func mixedUrgenciesOverASlowingFailingBackend() async throws {
        let backend = Backend.remote("simulation.mixed", capacity: 4)
        let fetch = backend.readOnly("fetch")
        // Timers fire only when everything sleeps: with early timers, virtual
        // time passes while a woken task waits to run, as on a starved CPU,
        // and a deadline is cooperative, so "nothing outlives its deadline"
        // would measure the scheduler.
        let schedule = SimulationSchedule(.portfolio, earlyTimers: false)
        try await simulate(seeds: 0..<UInt64(12 * testScale), schedule: schedule) { context in
            let calls = SendableBox<[Call]>([])
            // Each seed's own draws for the backend's behaviour.
            let random = SendableBox(OperationPropertyTests.Generator(state: context.seed &+ 1))
            @Sendable func draw(_ range: Range<Int>) -> Int { random.mutate { Int.random(in: range, using: &$0) } }

            /// The backend: slower as time goes on, failing one call in six.
            @Sendable func call(_ attempt: Attempt) async throws -> Int {
                let now = Ambient.current.clock.now.offset
                let slowing = Int(now.components.seconds) * 20
                try await Ambient.sleep(for: .milliseconds(100 + draw(0..<(1_500 + slowing))))
                if draw(0..<6) == 0 { throw Transient() }
                return attempt.number
            }

            @Sendable func caller(_ urgency: Urgency, after delay: Duration) async {
                try? await Ambient.sleep(for: delay)
                let clock = Ambient.current.clock
                let start = clock.now.offset
                let first = SendableBox<Duration?>(nil)
                let result = await withUrgency(urgency) {
                    do throws(OperationError<any Error>) {
                        return Result<Int, OperationError<any Error>>.success(try await fetch.perform { attempt throws(any Error) in
                            first.mutate { $0 = $0 ?? Ambient.current.clock.now.offset }
                            return try await call(attempt)
                        })
                    } catch {
                        return .failure(error)
                    }
                }
                calls.mutate {
                    $0.append(Call(urgency: urgency, start: start, end: clock.now.offset, firstAttempt: first.value, stop: result.error?.stopName))
                }
            }

            await withTaskGroup(of: Void.self) { group in
                // A crowd of patient work, arriving over a minute.
                for index in 0..<24 {
                    let urgency: Urgency = [.background, .utility, .userInitiated][index % 3]
                    let delay = Duration.milliseconds(draw(0..<60_000))
                    group.addTask { await caller(urgency, after: delay) }
                }
                // Taps, at most three at a time (fewer than the capacity).
                for wave in 0..<4 {
                    for _ in 0..<3 {
                        let delay = Duration.seconds(wave * 20) + .milliseconds(draw(0..<1_000))
                        group.addTask { await caller(.interactive, after: delay) }
                    }
                }
            }

            let finished = calls.value
            try #require(finished.count == 36)
            for call in finished {
                // Nothing outlives its deadline.
                let deadline = fetch.policy(at: call.urgency).deadline
                try #require(call.end - call.start <= deadline, "seed \(context.seed): \(call)")
                // A tap gets a slot within its deadline.
                if call.urgency == .interactive {
                    let first = try #require(call.firstAttempt, "seed \(context.seed): a tap got no slot: \(call)")
                    try #require(first - call.start < deadline, "seed \(context.seed): \(call)")
                }
            }
            // Nothing leaks: every slot and every waiter's place came back.
            let state = try #require(Ambient.current.backends.existing(backend))
            try #require(state.slots.isIdle)
        }
    }
}
