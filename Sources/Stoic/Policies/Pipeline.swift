/// Several policies applied to one operation, outermost first.
///
/// A policy around another policy would, taken literally, throw
/// `PolicyError<PolicyError<Failure>>`: the outer one's `.failed` would carry
/// the inner one's refusal. A pipeline removes the nesting by construction. It
/// runs each stage with *the rest of the pipeline* as that stage's operation —
/// an operation whose failure type is `PolicyError<Failure>` — and maps the
/// stage's error back down: `.rejected(r)` and `.failed(.rejected(r))` become
/// `.rejected(r)`, and `.failed(.failed(f))` becomes `.failed(f)`. However
/// many stages there are, the caller sees one flat `PolicyError<Failure>`.
///
/// Stages see an inner stage's refusal as their operation's error, which is
/// what lets a ``CircuitBreaker`` decline to count it, and ``Retrying`` honour
/// its `retryAfter`.
///
/// **Order matters**, and the recommended one is the order of Polly's
/// documentation and resilience4j's decorators: *overall timeout → retry →
/// circuit breaker → rate limiter → bulkhead → operation,* with the attempt
/// timeout given to ``Retrying`` (`attemptTimeout`). A timeout cannot be a
/// stage (it must run the operation in a child task, which an inline `Policy`
/// operation cannot do), but the overall one nests around a pipeline without
/// changing its error type, because `withTimeout` passes the operation's error
/// through:
///
///     let pipeline = Pipeline(
///         Retrying(.exponential(base: .milliseconds(200)).jittered().attempts(3), attemptTimeout: .seconds(2)),
///         CircuitBreaker(label: "api"),
///         RateLimiter(rate: 50, burst: 100, label: "api"),
///         Bulkhead(maxConcurrent: 8, queueLimit: 16, label: "api")
///     )
///
///     try await withTimeout(.seconds(10)) {                  // the whole call, retries included
///         try await pipeline.execute { () async throws(APIError) -> Reply in
///             try await client.send(request)                 // each attempt: Retrying bounds it
///         }
///     }
public struct Pipeline: Policy {
    private let stages: [any Policy]

    /// A pipeline of `stages`, outermost first.
    public init(_ stages: [any Policy]) {
        self.stages = stages
    }

    /// A pipeline of `stages`, outermost first.
    public init(_ stages: any Policy...) {
        self.stages = stages
    }

    /// The number of stages.
    public var stageCount: Int { stages.count }

    public nonisolated(nonsending) func execute<R, Failure: Error>(
        _ operation: nonisolated(nonsending) () async throws(Failure) -> R
    ) async throws(PolicyError<Failure>) -> R {
        try await run(from: 0, operation)
    }

    private nonisolated(nonsending) func run<R, Failure: Error>(
        from index: Int,
        _ operation: nonisolated(nonsending) () async throws(Failure) -> R
    ) async throws(PolicyError<Failure>) -> R {
        guard index < stages.count else {
            do throws(Failure) {
                return try await operation()
            } catch {
                throw .failed(error)
            }
        }
        do throws(PolicyError<PolicyError<Failure>>) {
            return try await stages[index].execute { () async throws(PolicyError<Failure>) -> R in
                try await self.run(from: index + 1, operation)
            }
        } catch {
            throw error.flattened()
        }
    }
}

extension PolicyError {
    /// A doubly wrapped error, as one: the nested policy's refusal or the
    /// operation's own failure, never `PolicyError` inside `PolicyError`.
    func flattened<Inner: Error>() -> PolicyError<Inner> where Failure == PolicyError<Inner> {
        switch self {
        case .rejected(let rejection): .rejected(rejection)
        case .failed(.rejected(let rejection)): .rejected(rejection)
        case .failed(.failed(let failure)): .failed(failure)
        }
    }
}

/// ``retry(_:budget:classify:nesting:clock:label:fileID:line:operation:)`` as
/// a pipeline stage.
///
/// Place it outside a ``CircuitBreaker`` so every attempt is judged. An open
/// breaker's refusal arrives as the attempt's error: when its `retryAfter`
/// is longer than the schedule's next delay the retry stops at once (the
/// breaker said "fail fast"), and otherwise it waits that long, jittered
/// upward by up to a tenth so callers do not all reach the probe at once. (A
/// half-open rejection has no `retryAfter` and is retried on the schedule.)
///
/// The classifier is typed `RetryClassifier<any Error>` because a stage does
/// not know the failure type of the pipeline it will sit in, and it is handed
/// the operation's own error, unwrapped. The budget is per call site of
/// `Retrying(…)`, unless you give one.
///
/// **Stops that are refusals are rejections.** Unlike `retry`, which has
/// only the operation's error to throw, the stage reports why it stopped when
/// that was not the operation's doing: its caller was cancelled while it
/// waited (`.cancelled`, or `.deadlineExceeded` when a deadline cancelled
/// it), the next attempt could not finish before the deadline
/// (`.deadlineExceeded`, with the delay it needed as `retryAfter`), or the
/// budget ran dry (`.budgetExhausted`). Any other stop throws the last
/// attempt's error.
///
/// Give it an `attemptTimeout` to bound each attempt, as
/// ``retry(_:attemptTimeout:budget:classify:nesting:clock:label:fileID:line:operation:)``
/// does: an attempt that runs out of time is cancelled and counts as
/// transient, so it is retried. Prefer this to a `withTimeout` inside the
/// operation: `Retrying` sees only the error the cut-off attempt threw, which
/// it cannot tell from a cancellation of the caller, and stops on it. The
/// cost is that a ``CircuitBreaker`` inside the stage sees the cut-off as a
/// cancellation, which it does not count. Each attempt runs in a child task,
/// on the caller's actor.
public struct Retrying: Policy {
    private let schedule: BoundedSchedule
    private let budget: RetryBudget
    private let classify: RetryClassifier<any Error>
    private let nesting: RetryNesting
    private let attemptTimeout: Duration?
    private let label: String?
    private let fileID: String
    private let line: UInt

    public init(
        _ schedule: BoundedSchedule,
        budget: RetryBudget = .perCallSite,
        classify: RetryClassifier<any Error> = .standard,
        nesting: RetryNesting = .singleAttempt,
        attemptTimeout: Duration? = nil,
        label: String? = nil,
        fileID: String = #fileID,
        line: UInt = #line
    ) {
        self.schedule = schedule
        self.budget = budget
        self.classify = classify
        self.nesting = nesting
        self.attemptTimeout = attemptTimeout
        self.label = label
        self.fileID = fileID
        self.line = line
    }

    public nonisolated(nonsending) func execute<R, Failure: Error>(
        _ operation: nonisolated(nonsending) () async throws(Failure) -> R
    ) async throws(PolicyError<Failure>) -> R {
        // The classifier sees the operation's own error, not the PolicyError
        // a pipeline wraps it in, so the stage decides the same way alone and
        // in a pipeline (and as a breaker's recordWhen would).
        let classify = self.classify
        let typed = RetryClassifier<Failure> { failure in
            classify.decision(for: failure.unwrappedForClassification, attemptTimedOut: false)
        }
        do throws(RetryStopped<Failure>) {
            if let attemptTimeout {
                return try await retryBoundingEachAttempt(
                    schedule, attemptTimeout: attemptTimeout, budget: budget, classify: typed, nesting: nesting,
                    label: label, fileID: fileID, line: line, operation: operation
                )
            }
            return try await retryInline(
                schedule, budget: budget, classify: typed, nesting: nesting, clock: nil,
                label: label, fileID: fileID, line: line
            ) { (_: Attempt) async throws(Failure) -> R in
                try await operation()
            }
        } catch {
            throw policyError(for: error)
        }
    }

    /// What the stage throws for a stop: a rejection when retrying was
    /// refused (the caller left, the deadline or the budget ran out), the
    /// operation's own error otherwise.
    private func policyError<Failure>(for stop: RetryStopped<Failure>) -> PolicyError<Failure> {
        switch stop.reason {
        case .cancelled:
            let reason: Rejection.Reason = CancellationCause.current == .deadline ? .deadlineExceeded : .cancelled
            return .rejected(Rejection(reason, label: label))
        case .deadline(let needed):
            return .rejected(Rejection(.deadlineExceeded, label: label, retryAfter: needed))
        case .budgetExhausted:
            return .rejected(Rejection(.budgetExhausted, label: label))
        case .nested, .permanent, .exhausted, .breakerOpen:
            return .failed(stop.lastError)
        }
    }
}
