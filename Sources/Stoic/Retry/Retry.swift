internal import Synchronization

/// One attempt of a retried operation.
public struct Attempt: Sendable, Hashable, CustomStringConvertible {
    /// 1 for the first attempt, 2 for the first retry, and so on.
    public let number: Int

    /// Time since the first attempt began.
    public let elapsed: Duration

    /// Whether this is a retry rather than the first attempt.
    public var isRetry: Bool { number > 1 }

    /// The idempotency key of the operation this attempt belongs to: the same
    /// on every attempt of one `retry`, and on every attempt of one `hedge`.
    /// Each run of `recur` is an operation of its own and has its own key.
    ///
    /// Send it with any request that changes something, and a server that
    /// deduplicates can recognise a retry as the request it already handled.
    /// Because `retry` hands it to every attempt, the key cannot be drawn
    /// afresh per attempt by mistake (the bug `stoic.key-inside-retry`
    /// catches when the key is drawn by hand):
    ///
    ///     try await retry(.exponential(base: .seconds(1)).attempts(5)) { attempt in
    ///         try await payments.charge(order, idempotencyKey: attempt.idempotencyKey)
    ///     }
    ///
    /// The key is drawn from the ambient random source the first time any
    /// attempt reads it, as ``IdempotencyKey/random(fileID:line:)`` would draw
    /// it at the call site of the `retry`: an operation that never asks costs
    /// nothing, and under a seed the key is reproducible.
    public var idempotencyKey: IdempotencyKey { operation.idempotencyKey }

    /// What every attempt at one operation shares.
    let operation: OperationIdentity

    init(number: Int, elapsed: Duration, operation: OperationIdentity) {
        self.number = number
        self.elapsed = elapsed
        self.operation = operation
    }

    public var description: String { "attempt \(number) at +\(elapsed)" }

    /// Attempts are equal when their number and elapsed time are; the
    /// operation they belong to is identity, not value.
    public static func == (lhs: Attempt, rhs: Attempt) -> Bool {
        lhs.number == rhs.number && lhs.elapsed == rhs.elapsed
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(number)
        hasher.combine(elapsed)
    }
}

/// What the attempts at one operation share: its idempotency key, drawn the
/// first time an attempt asks for it. Attempts of a hedge run concurrently,
/// so the draw happens under a lock, once.
final class OperationIdentity: Sendable {
    private let fileID: String
    private let line: UInt
    private let key = Mutex<IdempotencyKey?>(nil)

    init(fileID: String, line: UInt) {
        self.fileID = fileID
        self.line = line
    }

    var idempotencyKey: IdempotencyKey {
        key.withLock { key in
            if let key { return key }
            let drawn = IdempotencyKey.random(fileID: fileID, line: line)
            key = drawn
            return drawn
        }
    }
}

/// What to do after an attempt fails.
public enum RetryDecision: Sendable, Hashable {
    /// Try again after the schedule's delay.
    case retry
    /// Try again after this delay instead of the schedule's own — a server's
    /// `Retry-After`, say. The schedule still bounds the number of attempts,
    /// the budget and the deadline still apply, and the wait is capped at five
    /// minutes, come what may (design/02).
    case retryAfter(Duration)
    /// Do not try again: the failure is permanent.
    case stop
}

/// An error that knows whether retrying could help.
///
/// Conform your own error types so every retry classifies them the same way:
///
///     extension SyncError: Retryable {
///         var retryDecision: RetryDecision {
///             switch self {
///             case .offline, .serverBusy: .retry
///             case .rateLimited(let after): .retryAfter(after)
///             case .unauthorized, .invalidPayload: .stop
///             }
///         }
///     }
public protocol Retryable: Error {
    var retryDecision: RetryDecision { get }
}

/// Decides, for each failure, whether a retry could help.
public struct RetryClassifier<Failure: Error>: Sendable {
    private let decide: @Sendable (Failure, _ attemptTimedOut: Bool) -> RetryDecision

    /// A classifier from a closure.
    public init(_ decide: @escaping @Sendable (Failure) -> RetryDecision) {
        self.decide = { failure, _ in decide(failure) }
    }

    private init(decideWithTimeout: @escaping @Sendable (Failure, Bool) -> RetryDecision) {
        self.decide = decideWithTimeout
    }

    /// The decision for one failure. Three rules hold whatever the
    /// classifier says: a defect anywhere in the error stops; an attempt that
    /// timed out is transient; a cancellation that did not come from the
    /// attempt's own timeout stops (the work was cancelled on purpose).
    func decision(for failure: Failure, attemptTimedOut: Bool) -> RetryDecision {
        if containsDefect(failure) { return .stop }
        if attemptTimedOut { return .retry }
        if containsCancellation(failure) { return .stop }
        return decide(failure, attemptTimedOut)
    }

    /// The default: retry unless the failure is known to be permanent.
    ///
    /// - A ``Defect`` stops (always, whatever the classifier).
    /// - A ``Retryable`` error decides for itself.
    /// - A ``Rejection`` (or a rejected ``PolicyError``) retries after its
    ///   `retryAfter` when it has one, and stops when retrying cannot help:
    ///   an exhausted budget, a shutdown, a wedged label.
    /// - `DecodingError` and `EncodingError` stop: the same bytes fail the
    ///   same way.
    /// - Anything else retries. The schedule is bounded, the budget caps the
    ///   load, and nested retries collapse to one attempt, so an unknown
    ///   error retried in vain costs a few bounded attempts, not an outage.
    public static var standard: RetryClassifier {
        RetryClassifier(decideWithTimeout: { failure, timedOut in
            if timedOut { return .retry }
            return standardDecision(for: failure) ?? .retry
        })
    }

    /// Retry only what is known to be transient: ``Retryable`` errors that
    /// say so, rejections with a `retryAfter`, and attempts that timed out.
    public static var transientOnly: RetryClassifier {
        RetryClassifier(decideWithTimeout: { failure, timedOut in
            if timedOut { return .retry }
            return standardDecision(for: failure) ?? .stop
        })
    }

    /// Never retry.
    public static var never: RetryClassifier {
        RetryClassifier { _ in .stop }
    }
}

/// The decision for errors whose nature Stoic knows, or `nil`.
private func standardDecision(for failure: any Error) -> RetryDecision? {
    switch failure {
    case let report as Report:
        return standardDecision(for: report.root)
    case let retryable as any Retryable:
        return retryable.retryDecision
    case let rejection as Rejection:
        return decision(for: rejection)
    case let policy as any RejectionCarrying:
        if let rejection = policy.carriedRejection { return decision(for: rejection) }
        return policy.carriedFailure.flatMap(standardDecision(for:))
    case let concurrent as any PrimaryFailureCarrying:
        return standardDecision(for: concurrent.primaryFailure)
    case is DecodingError, is EncodingError:
        return .stop
    default:
        return nil
    }
}

/// Whether `error`, or any error it wraps, is a ``Defect``.
func containsDefect(_ error: any Error) -> Bool {
    if error.isDefect { return true }
    if let report = error as? Report { return containsDefect(report.root) }
    if let policy = error as? any RejectionCarrying, let inner = policy.carriedFailure {
        return containsDefect(inner)
    }
    if let concurrent = error as? any PrimaryFailureCarrying {
        return concurrent.allFailures.contains(where: containsDefect)
    }
    return false
}

/// Whether `error` is, or wraps, a cancellation.
func containsCancellation(_ error: any Error) -> Bool {
    if error.isCancellation { return true }
    if let report = error as? Report { return containsCancellation(report.root) }
    if let rejection = error as? Rejection { return rejection.reason == .cancelled }
    if let policy = error as? any RejectionCarrying {
        if let rejection = policy.carriedRejection { return rejection.reason == .cancelled }
        if let inner = policy.carriedFailure { return containsCancellation(inner) }
    }
    return false
}

/// Lets classification see inside a ``ConcurrentFailure`` of any failure type.
protocol PrimaryFailureCarrying {
    var primaryFailure: any Error { get }
    var allFailures: [any Error] { get }
}

extension ConcurrentFailure: PrimaryFailureCarrying {
    var primaryFailure: any Error { primary }
    var allFailures: [any Error] { failures.map { $0 } }
}

private func decision(for rejection: Rejection) -> RetryDecision {
    switch rejection.reason {
    case .budgetExhausted, .shuttingDown, .abandonmentLimit, .cancelled:
        return .stop
    default:
        return rejection.retryAfter.map(RetryDecision.retryAfter) ?? .retry
    }
}

/// Lets classification see inside a `PolicyError` of any failure type.
protocol RejectionCarrying {
    var carriedRejection: Rejection? { get }
    var carriedFailure: (any Error)? { get }
}

extension PolicyError: RejectionCarrying {
    var carriedRejection: Rejection? { rejection }
    var carriedFailure: (any Error)? { failure }
}

/// What a retry inside another retry's attempt does.
public enum RetryNesting: Sendable, Hashable {
    /// Make one attempt and leave retrying to the outer retry. The default:
    /// retrying at more than one layer multiplies load (three layers of
    /// three attempts is 27 attempts per request).
    case singleAttempt
    /// Retry independently of the outer retry. Use only when the layers
    /// retry different dependencies.
    case allow
}

/// The retry whose attempt is running in the current task.
///
/// An attempt's context goes stale when the attempt ends, so a task that an
/// attempt left running (an unstructured `Task {}` inherits task-locals)
/// does not make every later retry it starts look nested.
final class RetryContext: Sendable {
    private let live = Mutex(true)

    @TaskLocal static var active: RetryContext?

    /// Whether a retry's attempt is running in the current task right now.
    static var isInsideAttempt: Bool {
        active?.live.withLock { $0 } ?? false
    }

    func end() {
        live.withLock { $0 = false }
    }
}

// MARK: - retry

/// Runs `operation`, retrying failures on `schedule`.
///
/// Before each retry, in order, `retry` stops and rethrows the last error if:
///
/// 1. the task running the retry was cancelled (a cancelled *attempt* — one
///    whose own timeout fired — is retried; a cancelled *caller* is not);
/// 2. this retry is nested inside another retry's attempt and `nesting` is
///    `.singleAttempt`;
/// 3. the classifier says `.stop` (a ``Defect`` always stops);
/// 4. the schedule is exhausted;
/// 5. the retry could not finish before ``Deadline/current`` — it would
///    start after the deadline, or start so close to it that an attempt as
///    long as the last one could not finish;
/// 6. the budget has no token to spend.
///
/// Otherwise it sleeps the schedule's delay (or the error's `retryAfter`)
/// on the ambient clock and tries again. The error thrown is always the last
/// attempt's error, unwrapped. Every decision is reported as an event.
///
/// The operation runs inline, on the caller's actor, and may capture
/// anything. To bound each attempt with a timeout, use
/// ``retry(_:attemptTimeout:budget:classify:nesting:clock:label:fileID:line:operation:)``.
public nonisolated(nonsending) func retry<R, Failure: Error>(
    _ schedule: BoundedSchedule,
    budget: RetryBudget = .perCallSite,
    classify: RetryClassifier<Failure> = .standard,
    nesting: RetryNesting = .singleAttempt,
    clock: AnyClock? = nil,
    label: String? = nil,
    fileID: String = #fileID,
    line: UInt = #line,
    operation: nonisolated(nonsending) (Attempt) async throws(Failure) -> R
) async throws(Failure) -> R {
    return try await retryLoop(
        schedule, budget: budget, classify: classify, nesting: nesting, clock: clock,
        label: label, fileID: fileID, line: line
    ) { attempt in
        await FaultPoint.hit("retry.attempt")
        let context = RetryContext()
        defer { context.end() }
        let result: Result<R, Failure> = await RetryContext.$active.withValue(context) {
            do throws(Failure) {
                return .success(try await operation(attempt))
            } catch {
                return .failure(error)
            }
        }
        return (result, false)
    }
}

/// Runs `operation`, retrying failures on `schedule`, with each attempt
/// bounded by `attemptTimeout`.
///
/// Each attempt runs under ``withTimeout(_:clock:tolerance:label:fileID:line:operation:)``:
/// when an attempt's timeout fires, the attempt is cancelled and awaited,
/// and its failure counts as transient whatever the classifier says
/// (a ``Defect`` still stops). The outer ``Deadline/current`` still bounds
/// everything. The closure runs in a child task, so, as with `Task {}`, it
/// must be `Sendable` and its result must be too; it inherits the caller's
/// actor.
public nonisolated(nonsending) func retry<R: Sendable, Failure: Error>(
    _ schedule: BoundedSchedule,
    attemptTimeout: Duration,
    budget: RetryBudget = .perCallSite,
    classify: RetryClassifier<Failure> = .standard,
    nesting: RetryNesting = .singleAttempt,
    clock: AnyClock? = nil,
    label: String? = nil,
    fileID: String = #fileID,
    line: UInt = #line,
    @_inheritActorContext operation: @escaping @Sendable @isolated(any) (Attempt) async throws(Failure) -> R
) async throws(Failure) -> R {
    return try await retryLoop(
        schedule, budget: budget, classify: classify, nesting: nesting, clock: clock,
        label: label, fileID: fileID, line: line
    ) { attempt in
        let context = RetryContext()
        defer { context.end() }
        let outcome = await RetryContext.$active.withValue(context) {
            await runWithDeadline(
                .after(attemptTimeout, clock: clock),
                tolerance: nil,
                label: label.map { "\($0) attempt \(attempt.number)" },
                fileID: fileID,
                line: line
            ) { () async throws(Failure) -> R in
                try await operation(attempt)
            }
        }
        return (outcome.result, outcome.expired)
    }
}

/// ``retry(_:attemptTimeout:budget:classify:nesting:clock:label:fileID:line:operation:)``
/// for an operation that is not `Sendable`: the inline closure of a
/// ``Policy``, which `Retrying(attemptTimeout:)` runs.
///
/// The attempt is bounded by the same engine, so a timed-out attempt is
/// transient to the classifier in the same way. A timeout has to run the
/// attempt in a child task so that it can be cancelled without cancelling the
/// caller; the operation is therefore handed to that task (see
/// ``AttemptHandoff``), and runs there on the caller's actor.
nonisolated(nonsending) func retryBoundingEachAttempt<R, Failure: Error>(
    _ schedule: BoundedSchedule,
    attemptTimeout: Duration,
    budget: RetryBudget,
    classify: RetryClassifier<Failure>,
    nesting: RetryNesting,
    label: String?,
    fileID: String,
    line: UInt,
    operation: nonisolated(nonsending) () async throws(Failure) -> R
) async throws(Failure) -> R {
    let isolation = #isolation
    return try await retryLoop(
        schedule, budget: budget, classify: classify, nesting: nesting, clock: nil,
        label: label, fileID: fileID, line: line
    ) { attempt in
        let context = RetryContext()
        defer { context.end() }
        // A local function, not a closure: `withoutActuallyEscaping`'s own
        // body is not `nonsending`, and the operation must stay on the
        // caller's actor.
        nonisolated(nonsending) func bounded(
            _ escapable: nonisolated(nonsending) @escaping () async throws(Failure) -> R
        ) async -> DeadlineOutcome<AttemptResult<R>, Failure> {
            await AttemptHandoff(escapable).runBounded(
                on: isolation, context: context, timeout: attemptTimeout,
                label: label.map { "\($0) attempt \(attempt.number)" }, fileID: fileID, line: line
            )
        }
        let outcome = await withoutActuallyEscaping(operation, do: bounded)
        return (outcome.result.map(\.value), outcome.expired)
    }
}

/// A result carried out of an attempt's child task.
///
/// The attempt's task is awaited before `retryBoundingEachAttempt` goes on, so
/// the value is only ever touched by one task at a time, in turn.
// stoic:allow(unchecked-sendable): a hand-off between two tasks, never shared: the child finishes before the parent reads it
private struct AttemptResult<R>: @unchecked Sendable {
    let value: R
}

/// A policy's inline operation, handed to an attempt's child task.
///
/// An attempt timeout must cancel the attempt without cancelling its caller,
/// so the attempt has to run in a task of its own, while a ``Policy``'s
/// operation is neither `Sendable` nor escaping. The caller is suspended for
/// the whole time the child runs, so the operation is used by one task at a
/// time (the structured hand-off `withTaskGroup` makes), and it is called on
/// the caller's actor, so what it captures is touched where the caller would
/// have touched it.
// stoic:allow(unchecked-sendable): a hand-off to one child task that the caller awaits; used by one task at a time, on the caller's actor
private final class AttemptHandoff<R, Failure: Error>: @unchecked Sendable {
    private let operation: nonisolated(nonsending) () async throws(Failure) -> R

    init(_ operation: nonisolated(nonsending) @escaping () async throws(Failure) -> R) {
        self.operation = operation
    }

    func runBounded(
        on isolation: (any Actor)?,
        context: RetryContext,
        timeout: Duration,
        label: String?,
        fileID: String,
        line: UInt
    ) async -> DeadlineOutcome<AttemptResult<R>, Failure> {
        await RetryContext.$active.withValue(context) {
            await runWithDeadline(.after(timeout, clock: nil), tolerance: nil, label: label, fileID: fileID, line: line) { () async throws(Failure) -> AttemptResult<R> in
                try await self.run(on: isolation)
            }
        }
    }

    private func run(on isolation: isolated (any Actor)?) async throws(Failure) -> AttemptResult<R> {
        AttemptResult(value: try await operation())
    }
}

/// The most a server's `Retry-After` may delay a retry, whatever the device's
/// conditions (design/02): the cap is the last word, so a hot or low-power
/// device cannot stretch an hour-long wait to eight times that.
private let retryAfterCap = Duration.seconds(300)

/// The loop both forms of `retry` share; they differ only in how one
/// attempt runs.
private nonisolated(nonsending) func retryLoop<R, Failure: Error>(
    _ schedule: BoundedSchedule,
    budget: RetryBudget,
    classify: RetryClassifier<Failure>,
    nesting: RetryNesting,
    clock explicitClock: AnyClock?,
    label: String?,
    fileID: String,
    line: UInt,
    runAttempt: nonisolated(nonsending) (Attempt) async -> (result: Result<R, Failure>, timedOut: Bool)
) async throws(Failure) -> R {
    let ambient = Ambient.current
    let clock = explicitClock ?? ambient.clock
    let storage = budget.resolved(fileID: fileID, line: line, registry: ambient.budgets)
    let nested = RetryContext.isInsideAttempt && nesting == .singleAttempt
    // Built on the first failure: most calls succeed at once and never need it.
    var stepper: Schedule.Stepper?
    let start = clock.now
    let operation = OperationIdentity(fileID: fileID, line: line)
    var number = 1

    func report(_ name: EventName, _ fields: [Event.Field], level: Event.Level = .info) {
        ambient.instrumentation.record(Event(name, level: level, label: label, fields: fields, fileID: fileID, line: line))
    }

    storage?.deposit()

    while true {
        let attemptStart = clock.now
        let attempt = Attempt(number: number, elapsed: start.duration(to: attemptStart), operation: operation)
        let (result, timedOut) = await runAttempt(attempt)

        let error: Failure
        switch result {
        case .success(let value):
            if number > 1 {
                report("retry.succeeded", [.init("attempts", .int(number)), .init("elapsed", .duration(start.duration(to: clock.now)))])
            }
            return value
        case .failure(let failure):
            error = failure
        }

        let now = clock.now
        let attemptDuration = attemptStart.duration(to: now)
        let common: [Event.Field] = [.init("attempt", .int(number)), .init("error", .error(error))]

        // 1. The caller, not the attempt, was cancelled.
        if Task.isCancelled {
            report("retry.cancelled", common, level: .debug)
            throw error
        }
        // 2. Nested inside another retry.
        if nested {
            report("retry.nested", common, level: .notice)
            throw error
        }
        // 3. Classification.
        let decision = classify.decision(for: error, attemptTimedOut: timedOut)
        if decision == .stop {
            let defect = containsDefect(error)
            report(defect ? "retry.defect" : "retry.permanent", common, level: defect ? .error : .info)
            throw error
        }
        // 4. The schedule.
        if stepper == nil {
            stepper = schedule.makeStepper(random: ambient.random.generator(fileID: fileID, line: line))
        }
        guard let scheduled = stepper!.next(elapsed: start.duration(to: now)) else {
            report("retry.exhausted", common + [.init("elapsed", .duration(start.duration(to: now)))], level: .notice)
            throw error
        }
        var delay = scheduled
        var retryAfterCeiling: Duration?
        if case .retryAfter(let requested) = decision {
            // A server's wait replaces the schedule's delay for this retry;
            // the schedule's bound, the budget and the deadline still apply
            // (design/02). The five-minute ceiling is remembered here and
            // enforced last, so nothing after it can extend the wait.
            if requested > retryAfterCap {
                report("retry.after_capped", common + [
                    .init("requested", .duration(requested)),
                    .init("cap", .duration(retryAfterCap)),
                ], level: .notice)
            }
            retryAfterCeiling = retryAfterCap
            delay = max(.zero, requested)
        }
        // A struggling device backs off further: hot, saving power, or low on
        // memory. The cap is the last word either way: the schedule's own
        // for its delays, five minutes for a server's.
        let factor = ambient.conditions.current.backoffFactor
        if let ceiling = retryAfterCeiling {
            if factor > 1 { delay = delay.saturatingMultiplied(by: factor) }
            delay = min(delay, ceiling)
        } else if factor > 1 {
            delay = delay.stretched(by: factor, cap: schedule.schedule.node.delayCap)
        }
        // 5. The deadline.
        if let deadline = Deadline.current {
            let needed = delay.saturatingAdding(attemptDuration)
            if needed >= deadline.remaining {
                report("retry.deadline_skip", common + [
                    .init("delay", .duration(delay)),
                    .init("remaining", .duration(deadline.remaining)),
                ], level: .notice)
                throw error
            }
        }
        // 6. The budget.
        if let storage, !storage.withdraw(clock: clock) {
            report("retry.budget_exhausted", common, level: .warning)
            throw error
        }

        report("retry.attempt_failed", common + [
            .init("delay", .duration(delay)),
            .init("timed_out", .bool(timedOut)),
            .init("decision", .string(decision == .retry ? "retry" : "retry_after"), privacy: .public),
        ])
        do {
            try await clock.sleep(until: clock.now.advanced(by: delay), tolerance: nil)
        } catch _ {
            // Cancelled while waiting: the last real failure is the answer.
            report("retry.cancelled", common, level: .debug)
            throw error
        }
        if Task.isCancelled {
            report("retry.cancelled", common, level: .debug)
            throw error
        }
        number += 1
    }
}

/// An unbounded retry does not compile; this overload exists only to say how
/// to fix it.
@available(*, unavailable, message: "retry needs a bounded schedule: end it with .attempts(n), e.g. .exponential(base: .seconds(1)).attempts(5)")
public func retry<R, Failure: Error>(
    _ schedule: Schedule,
    budget: RetryBudget = .perCallSite,
    classify: RetryClassifier<Failure> = .standard,
    operation: (Attempt) async throws(Failure) -> R
) async throws(Failure) -> R {
    fatalError("unavailable")
}
