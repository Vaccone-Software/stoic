@testable import Stoic
import StoicTesting
import Testing

@Suite("Scopes")
struct ScopeTests {
    enum Failure: Error, Equatable { case boom }
    struct CleanupFailed: Error {}

    @Test func finalizersRunInReverseWithTheExit() async throws {
        let log = OrderLog()
        let value = try await withScope { (scope: borrowing Scope) throws(Failure) -> Int in
            let a = try await scope.acquire({ () throws(Failure) -> String in log.append("acquire a"); return "a" },
                                            release: { name, exit in log.append("release \(name) \(exit)") })
            let b = try await scope.acquire({ () throws(Failure) -> String in log.append("acquire b"); return "b" },
                                            release: { name, exit in log.append("release \(name) \(exit)") })
            scope.onExit { exit in log.append("onExit \(exit)") }
            _ = (a, b)
            return 42
        }
        #expect(value == 42)
        #expect(log.values == ["acquire a", "acquire b", "onExit success", "release b success", "release a success"])
    }

    @Test func aThrowingBodyStillReleasesAndItsErrorPassesThrough() async {
        let log = OrderLog()
        await #expect(throws: Failure.boom) {
            try await withScope { (scope: borrowing Scope) throws(Failure) in
                scope.onExit { exit in log.append("\(exit.isFailure)") }
                throw .boom
            }
        }
        #expect(log.values == ["true"])
    }

    @Test func aCancelledBodyStillReleases() async {
        let released = AsyncGate()
        let entered = AsyncGate()
        let exitSeen = SendableBox<String?>(nil)
        let task = Task {
            try await withScope { scope in
                scope.onExit { exit in
                    // Cleanup that respects cancellation would skip this
                    // sleep if it were not shielded.
                    try await Task.sleep(for: .milliseconds(5))
                    exitSeen.mutate { $0 = "\(exit)" }
                    released.open()
                }
                entered.open()
                try await Task.sleep(for: .seconds(60))
            }
        }
        await entered.wait()
        task.cancel()
        await released.wait()
        _ = try? await task.value
        #expect(exitSeen.value == "cancelled")
    }

    @Test func aRealErrorOnACancelledTaskIsAFailureNotACancellation() async {
        let exitSeen = SendableBox<String?>(nil)
        let cancelled = AsyncGate()
        let task = Task {
            // The task is cancelled, but the body fails for its own reason.
            await cancelled.wait()
            await #expect(throws: Failure.boom) {
                try await withScope { (scope: borrowing Scope) throws(Failure) in
                    scope.onExit { exit in exitSeen.mutate { $0 = "\(exit)" } }
                    throw .boom
                }
            }
        }
        task.cancel()
        cancelled.open()
        await task.value
        #expect(exitSeen.value == "failure(boom)")
    }

    @Test func aFailingFinalizerIsReportedAndDoesNotChangeTheOutcome() async throws {
        let events = RecordingInstrumentation()
        let log = OrderLog()
        let value = try await withTestAmbient(clock: ContinuousClock(), events: events) {
            try await withScope { (scope: borrowing Scope) throws(Failure) -> String in
                scope.onExit { _ in log.append("first registered, runs last") }
                scope.onExit(label: "flaky") { _ in throw CleanupFailed() }
                return "ok"
            }
        }
        #expect(value == "ok")
        #expect(log.values == ["first registered, runs last"])
        #expect(events.names.contains("scope.finalizer_failed"))
    }

    @Test func aHungFinalizerIsAbandonedAndTheNextOneRuns() async throws {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let ranAfter = AsyncGate()
        let hung = AsyncGate()
        let task = Task {
            await withTestAmbient(clock: clock, events: events) {
                await withScope(finalizerTimeout: .seconds(2)) { scope in
                    scope.onExit { _ in ranAfter.open() }
                    scope.onExit(label: "hangs") { _ in await hung.wait() }
                }
            }
        }
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(2))
        await ranAfter.wait()
        await task.value
        #expect(events.names.contains("scope.finalizer_abandoned"))
        hung.open()
    }

    @Test func theExitBudgetBoundsTheWholeExit() async throws {
        let clock = TestClock()
        let task = Task {
            await withTestAmbient(clock: clock) {
                await withScope(exitBudget: .seconds(3), finalizerTimeout: .seconds(10)) { scope in
                    for _ in 0..<3 { scope.onExit { _ in await AsyncGate().wait() } }
                }
            }
        }
        // First finalizer gets the whole 3 s budget; the others the 250 ms floor.
        await clock.waitForSleepers(count: 1)
        #expect(clock.pendingDeadlines.first?.offset == .seconds(3))
        await clock.advance(by: .seconds(3))
        await clock.waitForSleepers(count: 1)
        #expect(clock.pendingDeadlines.first?.offset == .seconds(3) + .milliseconds(250))
        await clock.advance(by: .milliseconds(250))
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .milliseconds(250))
        await task.value
    }

    @Test func aFailedAcquireRegistersNothing() async {
        let log = OrderLog()
        await #expect(throws: Failure.boom) {
            try await withScope { (scope: borrowing Scope) throws(Failure) in
                _ = try await scope.acquire({ () throws(Failure) -> Int in 1 }, release: { _, _ in log.append("release 1") })
                _ = try await scope.acquire({ () throws(Failure) -> Int in throw .boom }, release: { _, _ in log.append("release 2") })
            }
        }
        #expect(log.values == ["release 1"])
    }

    @Test func resourcesAreReusableDescriptions() async throws {
        let log = OrderLog()
        let resource = Resource<String, Never>(label: "conn") { log.append("open"); return "conn" }
            release: { _, _ in log.append("close") }
        await withScope { scope in
            let first = await scope.acquire(resource)
            let second = await scope.acquire(resource)
            #expect(first == second)
        }
        #expect(log.values == ["open", "open", "close", "close"])
    }

    // MARK: Saga

    @Test func aSuccessfulSagaCompensatesNothing() async throws {
        let log = OrderLog()
        try await withSaga { (saga: borrowing Saga) throws(Failure) in
            _ = try await saga.step({ () throws(Failure) -> Int in 1 }, compensate: { _ in log.append("undo 1") })
            _ = try await saga.step({ () throws(Failure) -> Int in 2 }, compensate: { _ in log.append("undo 2") })
        }
        #expect(log.values.isEmpty)
    }

    @Test func aFailedSagaCompensatesCompletedStepsInReverse() async {
        let log = OrderLog()
        await #expect(throws: Failure.boom) {
            try await withSaga { (saga: borrowing Saga) throws(Failure) in
                _ = try await saga.step({ () throws(Failure) -> String in "order" }, compensate: { log.append("cancel \($0)") })
                _ = try await saga.step({ () throws(Failure) -> String in "charge" }, compensate: { log.append("refund \($0)") })
                _ = try await saga.step({ () throws(Failure) -> String in throw .boom }, compensate: { log.append("never \($0)") })
            }
        }
        #expect(log.values == ["refund charge", "cancel order"])
    }

    @Test func aFailingCompensationDoesNotStopTheOthers() async {
        let log = OrderLog()
        await #expect(throws: Failure.boom) {
            try await withSaga { (saga: borrowing Saga) throws(Failure) in
                _ = try await saga.step({ () throws(Failure) -> Int in 1 }, compensate: { _ in log.append("undo 1") })
                _ = try await saga.step({ () throws(Failure) -> Int in 2 }, compensate: { _ in throw CleanupFailed() })
                throw .boom
            }
        }
        #expect(log.values == ["undo 1"])
    }

    // MARK: TaskScope

    @Test func forksStopBeforeResourcesAreReleased() async throws {
        let log = OrderLog()
        let result = try await withTaskScope { scope in
            _ = await scope.acquire({ "socket" }, release: { _, _ in log.append("release") })
            scope.fork(label: "heartbeat") {
                do { try await Task.sleep(for: .seconds(60)) } catch {
                    log.append("heartbeat stopped: \(CancellationCause.current?.rawValue ?? "none")")
                    throw error
                }
            }
            try await Task.sleep(for: .milliseconds(5))
            return "done"
        }
        #expect(result == "done")
        #expect(log.values == ["heartbeat stopped: scope_ended", "release"])
    }

    @Test func aFailingForkCancelsTheBodyAndIsThrown() async {
        let bodyCause = SendableBox<CancellationCause?>(nil)
        do {
            _ = try await withTaskScope { scope -> Int in
                scope.fork(label: "broken") { throw Failure.boom }
                do { try await Task.sleep(for: .seconds(60)) } catch {
                    bodyCause.mutate { $0 = CancellationCause.current }
                    throw error
                }
                return 1
            }
            Issue.record("expected a failure")
        } catch let failure as ConcurrentFailure<any Error> {
            #expect(failure.failures.count == 1)
            #expect(failure.primary as? Failure == .boom)
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(bodyCause.value == .siblingFailed)
    }

    @Test @MainActor func theTaskScopeBodyRunsOnTheCallersActor() async throws {
        final class Counter { var value = 0 }
        let counter = Counter()
        try await withTaskScope { _ in
            MainActor.assertIsolated()
            counter.value += 1
        }
        #expect(counter.value == 1)
    }
}
