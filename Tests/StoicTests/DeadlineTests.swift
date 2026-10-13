@testable import Stoic
import StoicTesting
import Testing

@Suite("Deadlines")
struct DeadlineTests {
    enum Failure: Error, Equatable { case boom }

    @Test(.failureMode("design/01", "the operation finishes first")) func anOperationThatFinishesFirstReturnsAndStopsTheTimer() async throws {
        let clock = TestClock()
        let value = try await withTestAmbient(clock: clock) {
            try await withTimeout(.seconds(5)) { () throws(Failure) -> Int in 42 }
        }
        #expect(value == 42)
        #expect(clock.sleeperCount == 0, "the timer must not outlive the operation")
    }

    @Test func aTypedErrorPassesThrough() async {
        await #expect(throws: Failure.boom) {
            try await withTimeout(.seconds(5)) { () throws(Failure) -> Int in throw .boom }
        }
    }

    @Test(.failureMode("design/01", "the deadline passes, operation honours cancellation")) func anExpiredDeadlineCancelsTheOperationWithACause() async throws {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let observed = SendableBox<CancellationCause?>(nil)
        let task = Task {
            try await withTestAmbient(clock: clock, events: events) {
                try await withTimeout(.seconds(2), label: "fetch") {
                    do {
                        try await Ambient.sleep(for: .seconds(60))
                    } catch {
                        observed.mutate { $0 = CancellationCause.current }
                        throw error
                    }
                }
            }
        }
        await clock.waitForSleepers(count: 2)
        await clock.advance(by: .seconds(2))
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(observed.value == .deadline)
        let expired = events.events(named: "deadline.expired")
        #expect(expired.count == 1)
        #expect(expired.first?.label == "fetch")
    }

    /// The Mac sleeps with a thirty-second timeout pending and wakes an hour
    /// later: the continuous clock counted the sleep, so the clock "jumps".
    @Test(.failureMode("design/01", "the Mac sleeps past the deadline")) func aClockJumpPastTheDeadlineFiresItAtOnce() async throws {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let observed = SendableBox<CancellationCause?>(nil)
        let deadline = await withTestAmbient(clock: clock) { Deadline.after(.seconds(30)) }
        #expect(!deadline.hasPassed)
        let task = Task {
            try await withTestAmbient(clock: clock, events: events) {
                try await withTimeout(.seconds(30), label: "sleepy") {
                    do {
                        try await Ambient.sleep(for: .seconds(3600))
                    } catch {
                        observed.mutate { $0 = CancellationCause.current }
                        throw error
                    }
                }
            }
        }
        await clock.waitForSleepers(count: 2)
        await clock.advance(by: .seconds(3600))   // one jump: no tick in between
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(observed.value == .deadline)
        #expect(deadline.hasPassed)
        #expect(deadline.remaining == .zero)
        let expired = events.events(named: "deadline.expired")
        #expect(expired.count == 1)
        #expect(clock.sleeperCount == 0)
    }

    @Test(.failureMode("design/01", "the deadline passes, operation ignores cancellation (cooperative)")) func anOperationThatIgnoresCancellationIsAwaited() async throws {
        let clock = TestClock()
        let gate = AsyncGate()
        let task = Task {
            try await withTestAmbient(clock: clock) {
                try await withTimeout(.seconds(1)) { () throws(Failure) -> String in
                    await gate.wait()   // not cancellation-aware
                    return "late"
                }
            }
        }
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(1))
        gate.open()
        #expect(try await task.value == "late")
    }

    @Test(.failureMode("design/01", "the caller is cancelled")) func cancellingTheCallerCancelsTheOperationAsUserRequested() async {
        let clock = TestClock()
        let observed = SendableBox<CancellationCause?>(nil)
        let task = Task {
            try await withTestAmbient(clock: clock) {
                try await withTimeout(.seconds(60)) {
                    do {
                        try await Ambient.sleep(for: .seconds(30))
                    } catch {
                        observed.mutate { $0 = CancellationCause.current }
                        throw error
                    }
                }
            }
        }
        await clock.waitForSleepers(count: 2)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(observed.value == .userRequested)
    }

    @Test(.failureMode("design/01", "an inner timeout is longer than the outer deadline")) func anOuterDeadlineIsTheCauseInsideAnInnerScope() async {
        let clock = TestClock()
        let observed = SendableBox<CancellationCause?>(nil)
        let task = Task {
            try await withTestAmbient(clock: clock) {
                try await withTimeout(.seconds(1)) {
                    try await withTimeout(.seconds(30)) {
                        do {
                            try await Ambient.sleep(for: .seconds(60))
                        } catch {
                            observed.mutate { $0 = CancellationCause.current }
                            throw error
                        }
                    }
                }
            }
        }
        await clock.waitForSleepers(count: 3)
        await clock.advance(by: .seconds(1))
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(observed.value == .deadline)
    }

    @Test(.failureMode("design/01", "an inner timeout is longer than the outer deadline")) func nestedDeadlinesNarrowAndNeverWiden() async throws {
        let clock = TestClock()
        try await withTestAmbient(clock: clock) {
            try await withTimeout(.seconds(2)) {
                let outer = try #require(Deadline.current)
                try await withTimeout(.seconds(30)) {
                    let inner = try #require(Deadline.current)
                    #expect(inner.instant == outer.instant)
                }
                try await withTimeout(.seconds(1)) {
                    let inner = try #require(Deadline.current)
                    #expect(inner.instant < outer.instant)
                }
            }
        }
    }

    @Test(.failureMode("design/01", "the deadline has already passed on entry")) func anAlreadyPassedDeadlineRunsTheOperationCancelled() async throws {
        let clock = TestClock()
        let deadline = Deadline(clock.erased.now, clock: clock.erased)
        let wasCancelled = try await withTestAmbient(clock: clock) {
            try await withDeadline(deadline) { () throws(Failure) -> Bool in Task.isCancelled }
        }
        #expect(wasCancelled)
    }

    @Test @MainActor func theOperationRunsOnTheCallersActor() async throws {
        final class Counter { var value = 0 }
        let counter = Counter()
        try await withTimeout(.seconds(5)) { () throws(Failure) in
            MainActor.assertIsolated()
            counter.value += 1
        }
        #expect(counter.value == 1)
    }

    @Test func remainingIsZeroOncePassed() async {
        let clock = TestClock()
        let deadline = Deadline.after(.seconds(3), clock: clock.erased)
        #expect(deadline.remaining == .seconds(3))
        await clock.advance(by: .seconds(5))
        #expect(deadline.remaining == .zero)
        #expect(deadline.hasPassed)
    }
}

/// A one-shot gate that ignores cancellation: models work that cannot be interrupted.
final class AsyncGate: Sendable {
    private let state = SendableBox<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.mutate { state -> Bool in
                if state.open { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// Tasks suspended at the gate right now.
    var waiterCount: Int { state.value.waiters.count }

    func open() {
        let waiters = state.mutate { state -> [CheckedContinuation<Void, Never>] in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }
}

@Suite("Expiring work")
struct ExpiringWorkTests {
    /// Runs `expiring.run` in a task whose work records why it stopped.
    static func blockedRun(
        _ expiring: ExpiringWork,
        within limit: Duration? = nil,
        observed: SendableBox<CancellationCause?>,
        started: AsyncGate
    ) -> Task<Void, any Error> {
        Task {
            try await expiring.run(within: limit) {
                started.open()
                do { try await Task.sleep(for: .seconds(3600)) } catch {
                    observed.mutate { $0 = CancellationCause.current }
                    throw error
                }
            }
        }
    }

    @Test func expiryCancelsTheWorkAndSaysWhy() async {
        let expiring = ExpiringWork()
        let observed = SendableBox<CancellationCause?>(nil)
        let started = AsyncGate()
        let task = Self.blockedRun(expiring, observed: observed, started: started)
        await started.wait()
        expiring.expire()   // no task.cancel(): expiry alone must reach the work
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(observed.value == .systemExpiring)
    }

    @Test func cancellingTheCallerReachesTheWork() async {
        let expiring = ExpiringWork()
        let observed = SendableBox<CancellationCause?>(nil)
        let started = AsyncGate()
        let task = Self.blockedRun(expiring, observed: observed, started: started)
        await started.wait()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(observed.value == .userRequested)
        #expect(!expiring.isExpired)
    }

    @Test func theGrantedTimeIsTheWorksDeadline() async {
        let clock = TestClock()
        let observed = SendableBox<CancellationCause?>(nil)
        let sawDeadline = SendableBox(false)
        await withTestAmbient(clock: clock) {
            let expiring = ExpiringWork()
            let task = Task {
                try await expiring.run(within: .seconds(30)) {
                    sawDeadline.mutate { $0 = Deadline.current != nil }
                    do { try await clock.sleep(for: .seconds(3600)) } catch {
                        observed.mutate { $0 = CancellationCause.current }
                        throw error
                    }
                }
            }
            await clock.waitForSleepers(count: 2)   // the work, and its deadline
            await clock.advance(by: .seconds(30))
            await #expect(throws: (any Error).self) { try await task.value }
        }
        #expect(sawDeadline.value)
        #expect(observed.value == .deadline)
    }

    @Test func expiryIsFinal() async {
        let expiring = ExpiringWork()
        expiring.expire()
        let ran = SendableBox(false)
        await #expect(throws: CancellationError.self) {
            try await expiring.run { ran.mutate { $0 = true } }
        }
        #expect(!ran.value)
    }

    @Test func runsDoNotShareACause() async throws {
        // One run cancelled by its caller must not make a later run's
        // unrelated cancellation read differently, nor the reverse.
        let expiring = ExpiringWork()
        for _ in 0..<2 {
            let observed = SendableBox<CancellationCause?>(nil)
            let started = AsyncGate()
            let task = Self.blockedRun(expiring, observed: observed, started: started)
            await started.wait()
            task.cancel()
            _ = await task.result
            #expect(observed.value == .userRequested)
        }
    }

    @Test(arguments: [
        (Double.greatestFiniteMagnitude, nil),   // UIKit, in the foreground
        (.infinity, nil), (.nan, nil), (0, nil), (-1, nil), (3601, nil),
        (29.5, Duration.milliseconds(29_500)), (3600, .seconds(3600)),
    ] as [(Double, Duration?)])
    func hostSecondsBecomeALimitOnlyWhenTheyAreOne(seconds: Double, limit: Duration?) {
        #expect(ExpiringWork.limit(fromSecondsRemaining: seconds) == limit)
    }
}
