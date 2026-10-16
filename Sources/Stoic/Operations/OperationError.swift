/// Why a declared operation's `perform` gave up, and what is known about the
/// backend's side.
///
/// A failure of an operation that changes something is two questions, not
/// one: why the call stopped (``stop``), and whether the backend acted
/// (``outcome``). A payment whose response was lost did not fail the way a
/// declined card did, and the error says so:
///
///     do {
///         receipt = try await Payments.subscribe.perform(idempotencyKey: checkout.key) { attempt in
///             try await api.subscribe(plan, idempotencyKey: attempt.idempotencyKey)
///         }
///     } catch let error where error.outcome == .unknown {
///         // It may have been charged: reconcile under checkout.key, never re-ask.
///     }
///
/// It is ``Retryable`` for a layer that catches it without having seen the
/// attempt settled (an error carried across tasks): an operation that
/// already retried by its own policy is not retried again unless nothing
/// reached the backend.
public struct OperationError<Failure: Error>: Error, CustomStringConvertible {
    /// Why the call stopped.
    public enum Stop: Sendable {
        /// The last attempt failed and retrying stopped on it: the failure
        /// was permanent, not eligible to repeat, or the schedule ran out.
        case failed(Failure)
        /// A policy refused or ended the call: `.circuitOpen`,
        /// `.bulkheadFull`, `.budgetExhausted`, or `.deadlineExceeded` (the
        /// deadline passed, or the next attempt could not finish before it).
        case rejected(Rejection)
        /// The caller was cancelled.
        case cancelled
    }

    /// What is known about the backend's side.
    public enum Outcome: Sendable, Hashable, CustomStringConvertible {
        /// Nothing reached the backend: every attempt was refused before it
        /// started, or failed with `neverReachedBackend`.
        case notExecuted
        /// The backend gave a permanent answer to the last attempt that
        /// reached it.
        case executed
        /// An attempt reached the backend and then was cut off or failed
        /// transiently, and no later attempt got a permanent answer: the
        /// backend may or may not have acted.
        case unknown

        public var description: String {
            switch self {
            case .notExecuted: "notExecuted"
            case .executed: "executed"
            case .unknown: "unknown"
            }
        }
    }

    /// Why the call stopped.
    public let stop: Stop

    /// What is known about the backend's side.
    public let outcome: Outcome

    /// The last attempt's own failure, if an attempt ran and had one.
    public let last: Failure?

    /// The attempts that ran, refused ones not counted.
    public let attempts: Int

    /// The operation's repeat safety, for diagnostics.
    public let safety: RepeatSafety

    /// For a `.keyed` operation, the key every attempt sent: reconcile
    /// under it. `nil` for other operations, and for a key Stoic made that
    /// no attempt read (which is a bug: `operation.key_unread`).
    public let idempotencyKey: IdempotencyKey?

    /// Whether the call made one attempt inside a `perform` on the same
    /// backend, which retries for it: the enclosing call classifies the
    /// failure itself, as if this layer were not there.
    let defersToEnclosing: Bool

    init(
        stop: Stop, outcome: Outcome, last: Failure?, attempts: Int, safety: RepeatSafety,
        idempotencyKey: IdempotencyKey?, defersToEnclosing: Bool = false
    ) {
        self.stop = stop
        self.outcome = outcome
        self.last = last
        self.attempts = attempts
        self.safety = safety
        self.idempotencyKey = idempotencyKey
        self.defersToEnclosing = defersToEnclosing
    }

    /// Whether this is the caller's cancellation.
    ///
    /// True for ``Stop/cancelled``, except when the outcome is
    /// ``Outcome/unknown`` on a `.keyed` or `.notRepeatable` operation: a
    /// payment that may have happened is never reported as cancellation, so
    /// a caller that swallows cancellation cannot swallow it. Stoic's own
    /// cancellation checks (retry, scopes, supervisors, reports) read it the
    /// same way.
    public var isCancellation: Bool {
        guard case .cancelled = stop else { return false }
        return !mayHaveActedUnsafely
    }

    /// Whether the backend may have acted on an operation that is not safe
    /// to repeat by itself.
    var mayHaveActedUnsafely: Bool {
        outcome == .unknown && (safety == .keyed || safety == .notRepeatable)
    }

    /// The rejection, when a policy refused or ended the call.
    public var rejection: Rejection? {
        if case .rejected(let rejection) = stop { return rejection }
        return nil
    }

    public var description: String {
        let why = switch stop {
        case .failed(let failure): "failed: \(failure)"
        case .rejected(let rejection): "rejected: \(rejection)"
        case .cancelled: "cancelled"
        }
        return "\(why); outcome \(outcome) after \(attempts) attempt\(attempts == 1 ? "" : "s") (\(safety))"
    }
}

extension OperationError: Retryable {
    /// `.stop` unless nothing reached the backend; then the rejection's, or
    /// the last failure's, own decision. The operation already retried by
    /// its policy; a layer that missed the settled mark must not multiply it.
    public var retryDecision: RetryDecision {
        guard outcome == .notExecuted || defersToEnclosing else { return .stop }
        if let rejection { return decision(for: rejection) }
        if case .cancelled = stop { return .stop }
        guard let last else { return .stop }
        if containsDefect(last) || containsCancellation(last) { return .stop }
        return standardDecision(for: last) ?? .retry
    }

    /// True when nothing reached the backend.
    public var neverReachedBackend: Bool {
        outcome == .notExecuted
    }
}

/// Lets classification see inside an ``OperationError`` of any failure type.
protocol OperationErrorCarrying {
    var carriedLast: (any Error)? { get }
    var carriedRejection: Rejection? { get }
    var carriedIsCancellation: Bool { get }
    var carriedNothingExecuted: Bool { get }
    var carriedDefersToEnclosing: Bool { get }
}

extension OperationError: OperationErrorCarrying {
    var carriedLast: (any Error)? { last }
    var carriedRejection: Rejection? { rejection }
    var carriedIsCancellation: Bool { isCancellation }
    var carriedNothingExecuted: Bool { outcome == .notExecuted }
    var carriedDefersToEnclosing: Bool { defersToEnclosing }
}
