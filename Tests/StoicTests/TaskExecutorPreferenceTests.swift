import Dispatch
@testable import Stoic
import StoicTesting
import Testing

/// A task executor on one Dispatch queue, so a probe can ask "am I on it?".
final class QueueExecutor: TaskExecutor {
    let queue = DispatchQueue(label: "test.executor")
    let key = DispatchSpecificKey<Bool>()

    init() {
        queue.setSpecific(key: key, value: true)
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = unsafe asUnownedTaskExecutor()
        // unsafe: the job is run exactly once, on this executor, as the
        // runtime requires of every executor.
        queue.async { unsafe job.runSynchronously(on: executor) }
    }

    var isCurrent: Bool { DispatchQueue.getSpecific(key: key) == true }
}

@Suite("Task executor preference")
struct TaskExecutorPreferenceTests {
    @Test func everyTaskStoicStartsPrefersTheAmbientExecutor() async throws {
        let executor = QueueExecutor()
        let onExecutor = SendableBox<[String: Bool]>([:])
        @Sendable func probe(_ name: String) { onExecutor.mutate { $0[name] = executor.isCurrent } }

        try await withAmbient({ $0.taskExecutor = executor }) {
            // State work.
            enum Light: Hashable, Sendable { case off, on }
            let machine = StateMachine<Light, Light>(initial: .off, label: "light") { _, to in .to(to) }
            let ran = AsyncGate()
            machine.whileIn(.on, label: "probe") { _ in probe("state work"); ran.open() }
            machine.send(.on)
            await ran.wait()

            // Superseding work.
            let slot = TaskSlot<Void, Never>(label: "probe")
            let delivered = AsyncGate()
            slot.run { probe("slot work") } deliver: { _ in delivered.open() }
            await delivered.wait()

            // A supervised child.
            let supervisor = Supervisor(label: "probe") {
                Child("child", restart: .temporary) { _ in probe("supervised child") }
            }
            try await supervisor.run()

            // Background work run until expiry.
            try await ExpiringWork().run { probe("expiring work") }
        }
        #expect(onExecutor.value == [
            "state work": true, "slot work": true, "supervised child": true, "expiring work": true,
        ])
    }

    @Test func withoutAPreferenceTasksRunWhereTheyAlwaysDid() async {
        let executor = QueueExecutor()
        let ran = AsyncGate()
        let onExecutor = SendableBox<Bool?>(nil)
        let slot = TaskSlot<Void, Never>(label: "probe")
        slot.run { onExecutor.mutate { $0 = executor.isCurrent } } deliver: { _ in ran.open() }
        await ran.wait()
        #expect(onExecutor.value == false)
    }
}
