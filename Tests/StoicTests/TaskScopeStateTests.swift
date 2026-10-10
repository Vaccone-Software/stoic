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
