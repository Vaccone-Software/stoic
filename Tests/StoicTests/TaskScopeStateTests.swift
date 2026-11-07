@testable import Stoic
import StoicTesting
import Testing

/// The windows inside `withTaskScope` that a whole-scope test cannot hit on
/// purpose, driven through the scope's state directly.
@Suite("TaskScope: state edges")
struct TaskScopeStateTests {
    struct Boom: Error {}

    @Test(.stoic(seed: 1)) func aForkFailingBeforeTheBodyArrivesStillCancelsIt() async {
        let state = TaskScopeState(label: "early")
        let siblingCancelled = TestGate()
        state.fork(label: "sibling") {
            do { try await Task.sleep(for: .seconds(60)) } catch {
                siblingCancelled.open()
                throw error
            }
        }
        state.fork(label: "broken") { throw Boom() }
        await eventually { state.failures.count == 1 }
        // The body task is only now created and handed over: the failure
        // happened first, so nothing had a body to cancel.
        let bodyStopped = TestGate()
        let body = Task<Void, Never> {
            do { try await Task.sleep(for: .seconds(60)) } catch { bodyStopped.open() }
        }
        state.setBody(body)
        await bodyStopped.wait()
        await siblingCancelled.wait()
        #expect(state.cause.cause == .siblingFailed, "the body is told why it was cancelled")
        await state.close()
    }

    @Test(.stoic(seed: 6)) func aForkFailingAfterTheBodyArrivedCancelsItAfterRecordingWhy() async {
        let state = TaskScopeState(label: "late")
        let causeWhenCancelled = SendableBox<CancellationCause?>(nil)
        let bodyStopped = TestGate()
        let body = Task<Void, Never> {
            do { try await Task.sleep(for: .seconds(60)) } catch {
                causeWhenCancelled.mutate { $0 = state.cause.cause }
                bodyStopped.open()
            }
        }
        state.setBody(body)
        state.fork(label: "broken") { throw Boom() }
        await bodyStopped.wait()
        #expect(causeWhenCancelled.value == .siblingFailed, "the cause is recorded before the body can see the cancel")
        await state.close()
    }

    @Test(.stoic(seed: 7)) func aBodyHandedOverWithoutAFailureIsNotCancelled() async {
        let state = TaskScopeState(label: "calm")
        let body = Task<Void, Never> {
            do { try await Task.sleep(for: .seconds(60)) } catch {}
        }
        state.setBody(body)
        // A fork that finishes cleanly is not a failure: nothing cancels the body.
        state.fork(label: "fine") {}
        #expect(await eventually { state.trackedForkCount == 0 })
        #expect(!body.isCancelled)
        #expect(state.cause.cause == nil)
        body.cancel()
        await body.value
        await state.close()
    }

    @Test(.stoic(seed: 8)) func onlyTheFirstOfSeveralFailuresCancelsTheBody() async {
        let state = TaskScopeState(label: "several")
        let cancels = SendableBox(0)
        let bodyStopped = TestGate()
        let body = Task<Void, Never> {
            do { try await Task.sleep(for: .seconds(60)) } catch {
                cancels.mutate { $0 += 1 }
                bodyStopped.open()
            }
        }
        state.setBody(body)
        state.fork(label: "first") { throw Boom() }
        state.fork(label: "second") { throw Boom() }
        await bodyStopped.wait()
        await eventually { state.failures.count == 2 }
        #expect(cancels.value == 1)
        #expect(state.cause.cause == .siblingFailed)
        await state.close()
    }

    @Test(.stoic(seed: 2)) func aClosedScopeNeverStartsARejectedFork() async {
        let state = TaskScopeState(label: "closed")
        await state.close()
        let ran = SendableBox(false)
        state.fork(label: "late") { ran.mutate { $0 = true } }
        #expect(await stoicTasksStillRunning().isEmpty)
        #expect(!ran.value, "a rejected fork must not run even one line")
        #expect(StoicTest.events.names.contains("scope.fork_after_exit"))
    }
}

/// A long-lived scope that forks per event: what it holds must not grow
/// with the number of forks that have come and gone.
@Suite("TaskScope: finished forks")
struct TaskScopeFinishedForkTests {
    struct Boom: Error {}

    @Test(.stoic(seed: 3), .failureMode("design/04", "a long-lived scope forks many short tasks"))
    func finishedForksAreForgotten() async throws {
        try await withTaskScope(label: "long-lived") { scope in
            let tasks = scope.tasks
            for round in 0..<10 {
                for _ in 0..<100 { scope.fork(label: "event") {} }
                #expect(await eventually { tasks.trackedForkCount == 0 }, "round \(round): \(tasks.trackedForkCount) still held")
            }
        }
    }

    @Test(.stoic(seed: 4)) func forgettingFinishedForksKeepsTheRunningOnesCancellableAndAwaited() async throws {
        let stopped = SendableBox(0)
        try await withTaskScope(label: "mixed") { scope in
            let tasks = scope.tasks
            for _ in 0..<50 { scope.fork(label: "short") {} }
            for _ in 0..<3 {
                scope.fork(label: "long") {
                    do { try await Task.sleep(for: .seconds(3600)) } catch {
                        stopped.mutate { $0 += 1 }
                        throw error
                    }
                }
            }
            #expect(await eventually { tasks.trackedForkCount == 3 })
        }
        #expect(stopped.value == 3, "every running fork was cancelled and awaited at exit")
    }

    @Test(.stoic(seed: 5)) func aFinishedForksFailureStillFailsTheScope() async {
        await #expect(throws: ConcurrentFailure<any Error>.self) {
            try await withTaskScope(label: "failing") { scope in
                let tasks = scope.tasks
                scope.fork(label: "broken") { throw Boom() }
                await eventually { tasks.trackedForkCount == 0 }
                try await Task.sleep(for: .seconds(3600))
            }
        }
    }
}
