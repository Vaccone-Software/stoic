@testable import Stoic
import StoicTesting
import Testing

/// The shared operation runs at the highest priority of the callers waiting
/// for it, not at the priority of whoever happened to arrive first.
///
/// The first caller starts at `.medium`, not `.background`: it has to run
/// before anything can escalate it, and macOS throttles background threads
/// and gives them no time while work of a higher class keeps every core busy.
/// Measured: with 60 busy loops at the default class beside it, a
/// `.background` first caller did not start within the time limit (both tests
/// failed at 60 s); with the same loops in the background class, both passed
/// in 2.4 s. `.medium` shares the cores fairly with default-class work, and
/// `.medium` to `.high` is an escalation as real as `.background` to `.high`.
@Suite("SingleFlight: priority")
struct SingleFlightPriorityTests {
    /// The priority the running task has once an escalation to `target` has
    /// reached it. The flight's task is registered after it starts, and an
    /// escalation that arrives in between is applied when the launch
    /// registers it: a moment later, but not before a starved thread has
    /// run, so the task reads its priority until it is raised. A bound turns
    /// an escalation that never comes into a failure.
    static func priority(awaiting target: TaskPriority) async -> TaskPriority {
        var spins = 0
        while Task.currentPriority < target, spins < 2_000_000 {
            spins += 1
            await Task.yield()
        }
        return Task.currentPriority
    }

    /// The result of `work`, or `CancellationError` as soon as the waiting
    /// task is cancelled, as Swift Testing cancels a test at its time limit.
    /// `AsyncGate.wait()` and `Task.value` do not wake for cancellation, so a
    /// test waiting on a task that is never scheduled would run past its limit
    /// instead of failing at it (it did: 108 s and 128 s against 60 s).
    /// `onCancel` cancels what the wait was for.
    static func cancellable<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T,
        onCancel: @escaping @Sendable () -> Void = {}
    ) async throws -> T {
        let worker = Task { try await work() }
        let slot = SendableBox<(continuation: CheckedContinuation<T, any Error>?, cancelled: Bool)>((nil, false))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = slot.mutate { state -> Bool in
                    if state.cancelled { return true }
                    state.continuation = continuation
                    return false
                }
                if cancelled { return continuation.resume(throwing: CancellationError()) }
                Task {
                    let result = await worker.result
                    slot.mutate { state in
                        defer { state.continuation = nil }
                        return state.continuation
                    }?.resume(with: result)
                }
            }
        } onCancel: {
            worker.cancel()
            onCancel()
            slot.mutate { state in
                state.cancelled = true
                defer { state.continuation = nil }
                return state.continuation
            }?.resume(throwing: CancellationError())
        }
    }

    /// A medium-priority caller starts the flight; a high-priority caller
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
            return await Self.priority(awaiting: .high)
        }
        let low = Task(priority: .medium) {
            try await withTestAmbient(clock: TestClock(), events: events) { try await flight.run("k", operation: operation) }
        }
        try await Self.cancellable { await started.wait() }
        let high = Task(priority: .high) {
            try await withTestAmbient(clock: TestClock(), events: events) { try await flight.run("k", operation: operation) }
        }
        #expect(await eventually { events.names.contains("singleflight.joined") })
        gate.open()
        let seen = try await Self.cancellable({ try await low.value }, onCancel: { low.cancel() })
        #expect(try await Self.cancellable({ try await high.value }, onCancel: { high.cancel() }) == seen,
                "both callers get the one result")
        #expect(seen >= .high, "the operation ran at \(seen.rawValue), not escalated to the joiner's priority")
    }

    /// A caller already waiting whose own task is escalated (something more
    /// urgent now awaits it) passes the escalation on to the flight.
    @Test(.timeLimit(.minutes(1))) func escalatingAWaitingCallerEscalatesTheFlight() async throws {
        let flight = SingleFlight<String, TaskPriority, Never>(label: "priority")
        let started = AsyncGate()
        let gate = AsyncGate()
        let low = Task(priority: .medium) {
            try await flight.run("k") { () async -> TaskPriority in
                started.open()
                await gate.wait()
                return await Self.priority(awaiting: .high)
            }
        }
        try await Self.cancellable { await started.wait() }
        #expect(await eventually { flight.waiterCount(for: "k") == 1 })
        low.escalatePriority(to: .high)
        // The escalation handler runs synchronously in `escalatePriority`.
        gate.open()
        let seen = try await Self.cancellable({ try await low.value }, onCancel: { low.cancel() })
        #expect(seen >= .high, "the operation ran at \(seen.rawValue)")
    }
}
