@testable import Stoic
import StoicTesting
import Synchronization
import Testing

// Shared fixtures for the operation suites (design/22).

/// A failure the backend may have acted on: a 502, a lost connection.
struct Transient: Error, Retryable, Equatable {
    var retryDecision: RetryDecision { .retry }
}

/// A permanent answer from the backend: a 404, a declined card.
struct Permanent: Error, Retryable, Equatable {
    var retryDecision: RetryDecision { .stop }
}

/// A failure that proves nothing was sent: no route, connection refused.
struct Offline: Error, Retryable, Equatable {
    var retryDecision: RetryDecision { .retry }
    var neverReachedBackend: Bool { true }
}

/// A failure nobody classified.
struct Unclassified: Error, Equatable {}

/// A bug.
struct Broken: Defect, Equatable {}

/// What one attempt of a scripted operation does.
enum Step: Sendable {
    case succeed
    case fail(any Error & Sendable)
    /// Sleeps on the ambient clock, then does the rest.
    indirect case after(Duration, Step)
    /// Sleeps until cancelled, then throws `CancellationError`.
    case hang
}

/// A scripted backend: each call takes the next step (the last repeats), and
/// every call is recorded with its attempt, key and start time.
final class Script: Sendable {
    struct Call: Sendable {
        let attempt: Int
        let key: IdempotencyKey?
        let at: Duration
        let urgency: Urgency
    }

    private let steps: Mutex<[Step]>
    private let recorded = Mutex<[Call]>([])
    private let readsKey: Bool

    init(_ steps: [Step], readsKey: Bool = true) {
        self.steps = Mutex(steps)
        self.readsKey = readsKey
    }

    var calls: [Call] { recorded.withLock { $0 } }
    var count: Int { recorded.withLock { $0.count } }
    var keys: [IdempotencyKey] { calls.compactMap(\.key) }

    /// One attempt.
    func call(_ attempt: Attempt) async throws -> Int {
        let at = Ambient.current.clock.now.offset
        recorded.withLock {
            $0.append(Call(attempt: attempt.number, key: readsKey ? attempt.idempotencyKey : nil, at: at, urgency: Urgency.current))
        }
        let step = steps.withLock { steps -> Step in
            steps.count > 1 ? steps.removeFirst() : steps[0]
        }
        return try await run(step, attempt: attempt.number)
    }

    private func run(_ step: Step, attempt: Int) async throws -> Int {
        switch step {
        case .succeed:
            return attempt
        case .fail(let error):
            throw error
        case .after(let delay, let next):
            try await Ambient.sleep(for: delay)
            return try await run(next, attempt: attempt)
        case .hang:
            try await Ambient.sleep(for: .seconds(1_000_000))
            return attempt
        }
    }
}

/// Runs `operation`'s `perform` with `script`, returning the value or the
/// `OperationError`.
func performing(
    _ operation: Backend.Operation,
    _ script: Script,
    key: IdempotencyKey? = nil
) async -> Result<Int, OperationError<any Error>> {
    do throws(OperationError<any Error>) {
        return .success(try await operation.perform(idempotencyKey: key) { attempt throws(any Error) in
            try await script.call(attempt)
        })
    } catch {
        return .failure(error)
    }
}

extension Result {
    /// The value, if there was one.
    var success: Success? {
        if case .success(let value) = self { return value }
        return nil
    }
}

extension OperationError {
    /// The stop, in words: `failed`, `cancelled`, or the rejection's reason.
    var stopName: String {
        switch stop {
        case .failed: "failed"
        case .rejected(let rejection): rejection.reason.rawValue
        case .cancelled: "cancelled"
        }
    }
}

/// Runs `body` as a deterministic simulation with no fault points and no
/// early timers: virtual time passes only when everything sleeps.
func simulated<R: Sendable>(
    seed: UInt64 = 1,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: @escaping @Sendable (SimulationContext) async throws -> R
) async throws -> Simulated<R> {
    try await simulate(seed: seed, faults: .none, schedule: .uniform, sourceLocation: sourceLocation, body)
}
