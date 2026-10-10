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
/// circuit breaker → rate limiter → bulkhead → attempt timeout → operation.*
/// A timeout cannot be a stage (it must run the operation in a child task,
/// which an inline `Policy` operation cannot do), but it nests around and
/// inside a pipeline without changing its error type, because `withTimeout`
/// passes the operation's error through:
///
///     let pipeline = Pipeline(
///         Retrying(.exponential(base: .milliseconds(200)).jittered().attempts(3)),
///         CircuitBreaker(label: "api"),
///         RateLimiter(rate: 50, burst: 100, label: "api"),
///         Bulkhead(maxConcurrent: 8, queueLimit: 16, label: "api")
///     )
///
///     try await withTimeout(.seconds(10)) {                  // the whole call, retries included
///         try await pipeline.execute { () async throws(APIError) -> Reply in
///             try await withTimeout(.seconds(2)) {           // each attempt
///                 try await client.send(request)
///             }
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
/// Place it outside a ``CircuitBreaker`` so every attempt is judged and an
/// open breaker's `retryAfter` shapes the backoff: the standard classifier
/// reads it from the rejection, which arrives as the attempt's error. (A
/// half-open rejection has no `retryAfter` and is retried on the schedule.)
///
/// The classifier is typed `RetryClassifier<any Error>` because a stage does
/// not know the failure type of the pipeline it will sit in; the standard
/// classifier sees through ``PolicyError``. The budget is per call site of
/// `Retrying(…)`, unless you give one.
public struct Retrying: Policy {
    private let schedule: BoundedSchedule
    private let budget: RetryBudget
    private let classify: RetryClassifier<any Error>
    private let nesting: RetryNesting
    private let label: String?
    private let fileID: String
    private let line: UInt

    public init(
        _ schedule: BoundedSchedule,
        budget: RetryBudget = .perCallSite,
        classify: RetryClassifier<any Error> = .standard,
        nesting: RetryNesting = .singleAttempt,
        label: String? = nil,
        fileID: String = #fileID,
        line: UInt = #line
    ) {
        self.schedule = schedule
        self.budget = budget
        self.classify = classify
        self.nesting = nesting
        self.label = label
        self.fileID = fileID
        self.line = line
    }

    public nonisolated(nonsending) func execute<R, Failure: Error>(
        _ operation: nonisolated(nonsending) () async throws(Failure) -> R
    ) async throws(PolicyError<Failure>) -> R {
        let classify = self.classify
        let typed = RetryClassifier<Failure> { failure in
            classify.decision(for: failure, attemptTimedOut: false)
        }
        do throws(Failure) {
            return try await retry(
                schedule, budget: budget, classify: typed, nesting: nesting,
                label: label, fileID: fileID, line: line
            ) { (_: Attempt) async throws(Failure) -> R in
                try await operation()
            }
        } catch {
            throw .failed(error)
        }
    }
}
