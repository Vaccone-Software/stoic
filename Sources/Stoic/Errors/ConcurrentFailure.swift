/// Every failure from work that ran concurrently.
///
/// When several children can fail — racers, a bounded parallel map, a task
/// scope's forks — reporting only the first throws away evidence. Stoic keeps
/// them all, in the order they completed. The first is the primary failure:
/// usually the cause, with the rest its consequences.
public struct ConcurrentFailure<Failure: Error>: Error, CustomStringConvertible {
    /// Every failure, in completion order. Never empty.
    public let failures: [Failure]

    /// Creates a value from a non-empty list of failures.
    public init(_ failures: [Failure]) {
        precondition(!failures.isEmpty, "ConcurrentFailure needs at least one failure")
        self.failures = failures
    }

    /// The first failure to complete.
    public var primary: Failure { failures[0] }

    public var description: String {
        if failures.count == 1 { return "\(primary)" }
        return "\(failures.count) failures; first: \(primary)"
    }
}

/// A programming error that was thrown rather than trapped.
///
/// A defect is never retried, never counted as a dependency's failure, never
/// handled by a fallback, and always reported at error level. Conform the
/// error types that mean "this code is wrong" — an invariant broken, an
/// impossible state reached — rather than "the world did something".
public protocol Defect: Error {}

extension Error {
    /// Whether this error is a ``Defect``.
    var isDefect: Bool { self is any Defect }

    /// Whether this error is a cancellation: never a failure, never retried.
    var isCancellation: Bool { self is CancellationError }
}
