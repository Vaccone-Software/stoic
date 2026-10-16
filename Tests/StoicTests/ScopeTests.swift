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

    /// Policies cannot throw `CancellationError` (their error type is
    /// `PolicyError`), so a cancelled wait is `.rejected(.cancelled)`: the
    /// library's spelling of cancellation. A scope must read it as one.
    @Test func aCancelledPolicyWaitEndsAScopeAsCancelledNotFailed() async throws {
        let exitSeen = SendableBox<String?>(nil)
        let rejected = SendableBox<Rejection.Reason?>(nil)
        let semaphore = AsyncSemaphore(permits: 1, label: "pool")
        let held = AsyncGate()
        let release = AsyncGate()
        let holder = Task { try await semaphore.withPermit { held.open(); await release.wait() } }
        await held.wait()
        let waiter = Task {
            do throws(PolicyError<Failure>) {
                try await withScope { (scope: borrowing Scope) async throws(PolicyError<Failure>) -> Void in
                    scope.onExit { exit in exitSeen.mutate { $0 = "\(exit)" } }
                    try await semaphore.withPermit { () async throws(Failure) -> Void in }
                }
            } catch {
                rejected.mutate { $0 = error.rejection?.reason }
            }
        }
        while semaphore.waiterCount == 0 { await Task.yield() }
        waiter.cancel()
        await waiter.value
        release.open()
        try await holder.value
        #expect(rejected.value == .cancelled)
        #expect(exitSeen.value == "cancelled")
    }

    @Test func aForkCancelledInAPolicyWaitIsNotAFailureOfTheScope() async throws {
        let semaphore = AsyncSemaphore(permits: 1, label: "pool")
        let held = AsyncGate()
        let release = AsyncGate()
        let holder = Task { try await semaphore.withPermit { held.open(); await release.wait() } }
        await held.wait()
        // The body ends while the fork waits for the permit: the scope cancels
        // the fork, whose wait ends `.rejected(.cancelled)`. That is the scope
        // stopping it, not the fork failing.
        try await withTaskScope { scope in
            scope.fork(label: "waiter") { try await semaphore.withPermit {} }
            while semaphore.waiterCount == 0 { await Task.yield() }
        }
        release.open()
        try await holder.value
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

    @Test func anAbandonedFinalizerIsCountedUntilItFinishes() async {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let hung = AsyncGate()
        let name = "scope finalizer hangs-\(UInt64.random(in: 0...UInt64.max))"
        let task = Task {
            await withTestAmbient(clock: clock, events: events) {
                await withScope(finalizerTimeout: .seconds(2)) { scope in
                    scope.onExit(label: String(name.dropFirst("scope finalizer ".count))) { _ in await hung.wait() }
                }
            }
        }
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(2))
        await task.value
        #expect(events.names.contains("scope.finalizer_abandoned"))
        #expect(AbandonedWork.current.contains { $0.label == name })

        hung.open()
        #expect(await eventually { !AbandonedWork.current.contains { $0.label == name } })
        #expect(await eventually { events.names.contains("abandoned.completed") })
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

    @Test func anExplicitTimeoutBelowTheFloorIsHonoured() async {
        let clock = TestClock()
        let task = Task {
            await withTestAmbient(clock: clock) {
                await withScope { scope in
                    scope.onExit(timeout: .milliseconds(10)) { _ in await AsyncGate().wait() }
                }
            }
        }
        await clock.waitForSleepers(count: 1)
        #expect(clock.pendingDeadlines.first?.offset == .milliseconds(10))
        // Past the floor too, so a regression fails the expectation above
        // rather than hanging the test.
        await clock.advance(by: ScopeState.exitDeadlineFloor)
        await task.value
    }

    @Test func aSpentBudgetStillLeavesEachFinalizerTheFloor() async {
        let clock = TestClock()
        let task = Task {
            await withTestAmbient(clock: clock) {
                await withScope(exitBudget: .zero, finalizerTimeout: .seconds(5)) { scope in
                    scope.onExit { _ in await AsyncGate().wait() }
                }
            }
        }
        await clock.waitForSleepers(count: 1)
        #expect(clock.pendingDeadlines.first?.offset == ScopeState.exitDeadlineFloor)
        await clock.advance(by: ScopeState.exitDeadlineFloor)
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
        let events = RecordingInstrumentation()
        await #expect(throws: Failure.boom) {
            try await withTestAmbient(clock: ContinuousClock(), events: events) {
                try await withSaga { (saga: borrowing Saga) throws(Failure) in
                    _ = try await saga.step({ () throws(Failure) -> Int in 1 }, compensate: { _ in log.append("undo 1") })
                    _ = try await saga.step({ () throws(Failure) -> Int in 2 }, compensate: { _ in throw CleanupFailed() })
                    throw .boom
                }
            }
        }
        #expect(log.values == ["undo 1"])
        #expect(events.names.contains("saga.compensation_failed"))
        #expect(!events.names.contains("scope.finalizer_failed"))
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

    @Test(.failureMode("design/04", "a forked child throws")) func aFailingForkCancelsTheBodyAndIsThrown() async {
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

    @Test(.failureMode("design/04", "a fork ignores cancellation")) func aForkThatIgnoresCancellationIsAbandonedAtTheForkTimeout() async throws {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let log = OrderLog()
        let hung = AsyncGate()
        let label = "stubborn-\(UInt64.random(in: 0...UInt64.max))"
        let task = Task {
            try await withTestAmbient(clock: clock, events: events) {
                try await withTaskScope(forkTimeout: .seconds(2), label: "forks") { scope in
                    _ = await scope.acquire(label: "quarantined", { 1 }, release: { _, _ in log.append("released") })
                    scope.onExit(label: "unsafe to release", ifWorkAbandoned: .quarantine) { _ in log.append("quarantine ran") }
                    scope.fork(label: label) { await hung.wait() }   // never looks at cancellation
                }
            }
        }
        await clock.waitForSleepers(count: 1)
        #expect(!events.names.contains("scope.fork_abandoned"), "the fork gets its time first")
        await clock.advance(by: .seconds(2))
        // The scope ends (it did not wait forever) and its finalizers run,
        // except the one that must not run under work that may still be using it.
        try await task.value
        #expect(log.values == ["released"])
        let abandoned = events.events(named: "scope.fork_abandoned")
        #expect(abandoned.count == 1)
        #expect(abandoned.first?.fields.contains { $0.key == "fork" && $0.value.description == label } == true)
        #expect(AbandonedWork.current.contains { $0.label.contains(label) })
        #expect(TaskLedger.current.contains { $0.label == label }, "the task ledger still names it")

        hung.open()
        #expect(await eventually { !AbandonedWork.current.contains { $0.label.contains(label) } })
        #expect(await eventually { events.names.contains("abandoned.completed") })
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

    /// A task scope cancelled by an enclosing deadline passes the deadline
    /// on as the cause, to its body and its forks: the scope's cancellation
    /// handler must not record "the user cancelled" over it.
    @Test func aTaskScopeUnderAnExpiringDeadlineGivesTheDeadlineAsTheCause() async {
        let clock = TestClock()
        let bodyCause = SendableBox<CancellationCause?>(nil)
        let forkCause = SendableBox<CancellationCause?>(nil)
        let task = Task {
            try await withTestAmbient(clock: clock) {
                try await withTimeout(.seconds(1)) {
                    try await withTaskScope { scope in
                        scope.fork(label: "pump") {
                            do { try await Ambient.sleep(for: .seconds(60)) } catch {
                                forkCause.mutate { $0 = CancellationCause.current }
                                throw error
                            }
                        }
                        do { try await Ambient.sleep(for: .seconds(60)) } catch {
                            bodyCause.mutate { $0 = CancellationCause.current }
                            throw error
                        }
                    }
                }
            }
        }
        await clock.waitForSleepers(count: 3)
        await clock.advance(by: .seconds(1))
        _ = try? await task.value
        #expect(bodyCause.value == .deadline)
        #expect(forkCause.value == .deadline)
    }

    /// Cancelled by someone no Stoic scope speaks for, a task scope's body
    /// and forks still read `.userRequested`.
    @Test func aCancelledTaskScopeGivesUserRequestedAsTheCause() async {
        let bodyCause = SendableBox<CancellationCause?>(nil)
        let forkCause = SendableBox<CancellationCause?>(nil)
        let started = AsyncGate()
        let task = Task {
            try await withTaskScope { scope in
                scope.fork(label: "pump") {
                    do { try await Task.sleep(for: .seconds(60)) } catch {
                        forkCause.mutate { $0 = CancellationCause.current }
                        throw error
                    }
                }
                started.open()
                do { try await Task.sleep(for: .seconds(60)) } catch {
                    bodyCause.mutate { $0 = CancellationCause.current }
                    throw error
                }
            }
        }
        await started.wait()
        task.cancel()
        _ = try? await task.value
        #expect(bodyCause.value == .userRequested)
        #expect(forkCause.value == .userRequested)
    }
}
