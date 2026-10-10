/// The error of a policy that may refuse to run an operation at all.
///
/// A policy — a circuit breaker, a bulkhead, a rate limiter, an abandoning
/// timeout — either ran the operation, which then failed with its own error,
/// or refused to run it (or stopped waiting for it). The two are different
/// facts with different remedies, so they are different cases.
///
/// Policies flatten: wrapping an operation that already throws
/// `PolicyError<F>` throws `PolicyError<F>`, never a nested `PolicyError`.
public enum PolicyError<Failure: Error>: Error, CustomStringConvertible {
    /// The operation never ran, or was abandoned before it finished.
    case rejected(Rejection)

    /// The operation ran and failed.
    case failed(Failure)

    /// The rejection, when the operation did not run.
    public var rejection: Rejection? {
        if case .rejected(let rejection) = self { return rejection }
        return nil
    }

    /// The operation's own error, when it ran and failed.
    public var failure: Failure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }

    public var description: String {
        switch self {
        case .rejected(let rejection): "rejected: \(rejection)"
        case .failed(let failure): "failed: \(failure)"
        }
    }
}

/// Why a policy refused to run an operation.
///
/// A struct rather than an enum so that new reasons can be added without
/// breaking anyone's exhaustive `switch`. Compare `reason` against the
/// static members.
public struct Rejection: Error, Hashable, Sendable, CustomStringConvertible {
    /// What kind of refusal this is.
    public let reason: Reason

    /// The label of the policy that refused.
    public let label: String?

    /// When the caller may usefully try again, if the policy knows.
    public let retryAfter: Duration?

    public init(_ reason: Reason, label: String? = nil, retryAfter: Duration? = nil) {
        self.reason = reason
        self.label = label
        self.retryAfter = retryAfter
    }

    /// A refusal's kind.
    public struct Reason: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// The deadline passed before the operation could start or finish.
        public static let deadlineExceeded = Reason(rawValue: "deadline_exceeded")
        /// Too many operations under this label are already abandoned.
        public static let abandonmentLimit = Reason(rawValue: "abandonment_limit")
        /// A circuit breaker is open.
        public static let circuitOpen = Reason(rawValue: "circuit_open")
        /// A bulkhead's capacity and queue are full.
        public static let bulkheadFull = Reason(rawValue: "bulkhead_full")
        /// A rate limiter has no permits left.
        public static let rateLimited = Reason(rawValue: "rate_limited")
        /// A retry budget has no tokens left.
        public static let budgetExhausted = Reason(rawValue: "budget_exhausted")
        /// The caller was cancelled before the operation could start or finish.
        public static let cancelled = Reason(rawValue: "cancelled")
        /// The owner of the policy is shutting down.
        public static let shuttingDown = Reason(rawValue: "shutting_down")

        public var description: String { rawValue }
    }

    public var description: String {
        var text = reason.rawValue
        if let label { text += " (\(label))" }
        if let retryAfter { text += ", retry after \(retryAfter)" }
        return text
    }
}
