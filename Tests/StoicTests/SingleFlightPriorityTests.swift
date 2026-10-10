@testable import Stoic
import StoicTesting
import Testing

/// The shared operation runs at the highest priority of the callers waiting
/// for it, not at the priority of whoever happened to arrive first.
@Suite("SingleFlight: priority")
struct SingleFlightPriorityTests {
    /// A background caller starts the flight; a high-priority caller
    /// joins it. The joiner waits on a continuation, which escalates nothing
    /// by itself: the flight must be escalated for it.
    @Test(.timeLimit(.minutes(1)), .failureMode("design/03", "a higher-priority caller joins a single flight"))
    func aHigherPriorityJoinerEscalatesTheFlight() async throws {
        let flight = SingleFlight<String, TaskPriority, Never>(label: "priority")
        let started = AsyncGate()
        let gate = AsyncGate()
        let events = RecordingInstrumentation()
        let operation: @concurrent @Sendable () async -> TaskPriority = {
            started.open()
            await gate.wait()
            return Task.currentPriority
        }
        let low = Task(priority: .background) {
            try await withTestAmbient(clock: TestClock(), events: events) { try await flight.run("k", operation: operation) }
        }
        await started.wait()
        let high = Task(priority: .high) {
            try await withTestAmbient(clock: TestClock(), events: events) { try await flight.run("k", operation: operation) }
        }
        #expect(await eventually { events.names.contains("singleflight.joined") })
        gate.open()
        let seen = try await low.value
        #expect(try await high.value == seen, "both callers get the one result")
        #expect(seen >= .high, "the operation ran at \(seen.rawValue), not escalated to the joiner's priority")
    }

    /// A caller already waiting whose own task is escalated (something more
    /// urgent now awaits it) passes the escalation on to the flight.
    @Test(.timeLimit(.minutes(1))) func escalatingAWaitingCallerEscalatesTheFlight() async throws {
        let flight = SingleFlight<String, TaskPriority, Never>(label: "priority")
        let started = AsyncGate()
        let gate = AsyncGate()
        let low = Task(priority: .background) {
            try await flight.run("k") { () async -> TaskPriority in
                started.open()
                await gate.wait()
                return Task.currentPriority
            }
        }
        await started.wait()
        #expect(await eventually { flight.waiterCount(for: "k") == 1 })
        low.escalatePriority(to: .high)
        // The escalation handler runs synchronously in `escalatePriority`.
        gate.open()
        let seen = try await low.value
        #expect(seen >= .high, "the operation ran at \(seen.rawValue)")
    }
}
