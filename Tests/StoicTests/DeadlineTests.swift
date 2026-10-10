@testable import Stoic
import StoicTesting
import Testing

@Suite("Deadlines")
struct DeadlineTests {
    enum Failure: Error, Equatable { case boom }

    @Test func anOperationThatFinishesFirstReturnsAndStopsTheTimer() async throws {
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

    @Test func anExpiredDeadlineCancelsTheOperationWithACause() async throws {
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

    @Test func anOperationThatIgnoresCancellationIsAwaited() async throws {
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

    @Test func cancellingTheCallerCancelsTheOperationAsUserRequested() async {
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

    @Test func anOuterDeadlineIsTheCauseInsideAnInnerScope() async {
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

    @Test func nestedDeadlinesNarrowAndNeverWiden() async throws {
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

    @Test func anAlreadyPassedDeadlineRunsTheOperationCancelled() async throws {
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
    @Test func expiryIsReportedAsTheSystemTakingTimeBack() async {
        let expiring = ExpiringWork()
        let observed = SendableBox<CancellationCause?>(nil)
        let started = AsyncGate()
        let task = Task {
            try await expiring.run {
                started.open()
                do { try await Task.sleep(for: .seconds(60)) } catch {
                    observed.mutate { $0 = CancellationCause.current }
                    throw error
                }
            }
        }
        await started.wait()
        expiring.expire()
        task.cancel()
        _ = try? await task.value
        #expect(observed.value == .systemExpiring)
    }
}
