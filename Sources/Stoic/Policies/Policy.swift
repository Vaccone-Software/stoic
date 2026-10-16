/// Something that decides whether, and when, an operation may run, and runs
/// it: a circuit breaker, a rate limiter, a bulkhead, a retry.
///
/// Every policy runs the operation inline, on the caller's actor, so the
/// operation may capture anything, and throws ``PolicyError``: `.failed` with
/// the operation's own error, or `.rejected` when the policy refused to run
/// it. Because the type is the same everywhere, policies compose in a
/// ``Pipeline`` without nesting their errors.
public protocol Policy: Sendable {
    /// Runs `operation` under this policy.
    nonisolated(nonsending) func execute<R, Failure: Error>(
        _ operation: nonisolated(nonsending) () async throws(Failure) -> R
    ) async throws(PolicyError<Failure>) -> R
}

extension Rejection {
    /// The rejection for a task that was already cancelled when a policy
    /// would have started work, or `nil`.
    ///
    /// Shared by every policy so that "cancelled before it began" and
    /// "deadline already passed" mean the same thing everywhere: the
    /// operation never ran and nothing was consumed.
    static func refusedBeforeStart(label: String) -> Rejection? {
        if Task.isCancelled {
            return Rejection(CancellationCause.current == .deadline ? .deadlineExceeded : .cancelled, label: label)
        }
        if let deadline = Deadline.current, deadline.hasPassed {
            return Rejection(.deadlineExceeded, label: label)
        }
        return nil
    }

    /// `self`, as `.deadlineExceeded` when the enclosing deadline is what
    /// cancelled the task: a wait that ends because the deadline cancelled
    /// it ran out of time; it was not abandoned by its caller.
    func attributingDeadline() -> Rejection {
        guard reason == .cancelled, CancellationCause.current == .deadline else { return self }
        return Rejection(.deadlineExceeded, label: label, retryAfter: retryAfter)
    }
}

extension Error {
    /// This error with every wrapper removed: the operation's own error, or
    /// the ``Rejection`` that a policy raised.
    ///
    /// The wrappers are the ones Stoic adds on the way out: ``PolicyError``
    /// layers (a stage inside a pipeline sees its inner stages' errors
    /// wrapped), a ``Report`` (`withContext` adds one), and a
    /// ``ConcurrentFailure`` (its primary failure stands for it). Everything
    /// that classifies an error — a breaker's `recordWhen`, a `Retrying`
    /// stage's classifier, the standard retry classifier — looks at this, so
    /// a policy decides the same way alone, in a pipeline, or around code
    /// that adds context.
    var unwrappedForClassification: any Error {
        var current: any Error = self
        while true {
            if let report = current as? Report {
                current = report.root
            } else if let policy = current as? any RejectionCarrying {
                if let rejection = policy.carriedRejection { return rejection }
                guard let inner = policy.carriedFailure else { return current }
                current = inner
            } else if let concurrent = current as? any PrimaryFailureCarrying {
                current = concurrent.primaryFailure
            } else {
                return current
            }
        }
    }
}
