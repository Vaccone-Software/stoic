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
    /// An operation started inside another's attempt (a library's `retry`
    /// called from the app's) derives its key from the enclosing one, so it
    /// too is the same on every attempt of the operation actually retried.
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
///
/// An error that proves the operation never reached the backend — no
/// connection was made, nothing was written — says so with
/// ``neverReachedBackend``. A declared operation that is not safe to repeat
/// is repeated only on such proof, its breaker does not count it, and its
/// outcome stays `.notExecuted` (design/22).
public protocol Retryable: Error {
    /// Whether, and when, another attempt could help.
    var retryDecision: RetryDecision { get }

    /// True when the failure proves the operation never reached the
    /// backend: no connection was made, nothing was written. Default
    /// `false`: claim it only when it is certain, because a
    /// `.notRepeatable` operation is repeated on its word.
    var neverReachedBackend: Bool { get }
}

extension Retryable {
    public var neverReachedBackend: Bool { false }
}

/// Decides, for each failure, whether a retry could help.
public struct RetryClassifier<Failure: Error>: Sendable {
    // The built-in classifiers are cases, not closures: a closure generic over
    // `Failure` captures its type, so building `.standard` allocated on
    // every `retry` call.
    private enum Kind: Sendable {
        case standard
        case transientOnly
        case never
        case custom(@Sendable (Failure) -> RetryDecision)
    }

    private let kind: Kind

    /// A classifier from a closure.
    public init(_ decide: @escaping @Sendable (Failure) -> RetryDecision) {
        self.kind = .custom(decide)
    }

    private init(kind: Kind) {
        self.kind = kind
    }

    /// The decision for one failure. Three rules hold whatever the
    /// classifier says: a defect anywhere in the error stops; an attempt that
    /// timed out is transient; a cancellation that did not come from the
    /// attempt's own timeout stops (the work was cancelled on purpose).
    func decision(for failure: Failure, attemptTimedOut: Bool) -> RetryDecision {
        if containsDefect(failure) { return .stop }
        if attemptTimedOut { return .retry }
        if containsCancellation(failure) { return .stop }
        switch kind {
        case .standard: return standardDecision(for: failure) ?? .retry
        case .transientOnly: return standardDecision(for: failure) ?? .stop
        case .never: return .stop
        case .custom(let decide): return decide(failure)
        }
    }

    /// This classifier for a stage's operation error `F`: what a custom
    /// classifier is handed is the error with its wrappers removed, so it
    /// decides the same way alone and in a pipeline.
    func unwrapping<F: Error>(to _: F.Type) -> RetryClassifier<F> where Failure == any Error {
        switch kind {
        case .standard: RetryClassifier<F>(kind: .standard)
        case .transientOnly: RetryClassifier<F>(kind: .transientOnly)
        case .never: RetryClassifier<F>(kind: .never)
        case .custom(let decide): RetryClassifier<F> { decide($0.unwrappedForClassification) }
        }
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
        RetryClassifier(kind: .standard)
    }

    /// Retry only what is known to be transient: ``Retryable`` errors that
    /// say so, rejections with a `retryAfter`, and attempts that timed out.
    public static var transientOnly: RetryClassifier {
        RetryClassifier(kind: .transientOnly)
    }

    /// Never retry.
    public static var never: RetryClassifier {
        RetryClassifier(kind: .never)
    }
}

/// An error type that Foundation boxes as its `NSError` when it is stored
/// in an `any Error`, and that can say what it is in Swift. A library that
/// owns such an `NSError` extension conforms it, so ``retryableView(of:)``
/// can find the ``Retryable`` conformance the Swift struct carries.
package protocol BridgedClassification {
    /// The error as the Swift value it bridges, if that is ``Retryable``;
    /// `nil` for anything else.
    var bridgedRetryable: (any Retryable)? { get }
}

/// `error` as a ``Retryable``, or `nil`.
///
/// On Apple platforms Foundation's bridged errors (`URLError`, `POSIXError`,
/// `CocoaError`) reach an `any Error` as their `NSError`, even when Swift
/// constructed them, and a protocol cast on the box cannot find the struct's
/// conformance: `as? any Retryable` is `nil`. So the cast is tried first, and
/// a class-typed error is then asked for its Swift value
/// (``BridgedClassification``). Everything that classifies an error asks
/// this, never the cast, or `StoicFoundation`'s table would apply on Linux
/// and nowhere on Apple platforms. Only a class-typed error is asked: casting
/// a Swift value to the protocol bridges it to an `NSError` first, which
/// allocates.
func retryableView(of error: any Error) -> (any Retryable)? {
    if let retryable = error as? any Retryable { return retryable }
    guard type(of: error) is AnyClass else { return nil }
    return (error as? any BridgedClassification)?.bridgedRetryable
}

/// The decision for errors whose nature Stoic knows, or `nil`.
func standardDecision(for failure: any Error) -> RetryDecision? {
    let failure = failure.unwrappedForClassification
    if let retryable = retryableView(of: failure) { return retryable.retryDecision }
    switch failure {
    case let rejection as Rejection:
        return decision(for: rejection)
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
    if let operation = error as? any OperationErrorCarrying {
        // A defect in a declared operation's last attempt is a defect to
        // whoever catches it.
        return operation.carriedLast.map(containsDefect) ?? false
    }
    if let policy = error as? any RejectionCarrying, let inner = policy.carriedFailure {
        return containsDefect(inner)
    }
    if let concurrent = error as? any PrimaryFailureCarrying {
        return concurrent.allFailures.contains(where: containsDefect)
    }
    return false
}

/// Whether `error` is, or wraps, a cancellation.
///
/// A ``ConcurrentFailure`` is a cancellation when its *primary* failure is:
/// the first child to end was cancelled, and the rest is the fallout. A
/// sibling cancelled because another child failed does not make the failure
/// a cancellation. (A defect is the other way round: any child's defect
/// makes the whole a defect, since a bug anywhere must be reported.)
///
/// An ``OperationError`` is a cancellation when its own `isCancellation`
/// says so: never when a keyed or non-repeatable operation may have acted,
/// so a scope or a supervisor reports a cancelled child's possible payment
/// as a failure, on purpose.
func containsCancellation(_ error: any Error) -> Bool {
    if error.isCancellation { return true }
    if let report = error as? Report { return containsCancellation(report.root) }
    if let operation = error as? any OperationErrorCarrying { return operation.carriedIsCancellation }
    if let rejection = error as? Rejection { return rejection.reason == .cancelled }
    if let policy = error as? any RejectionCarrying {
        if let rejection = policy.carriedRejection { return rejection.reason == .cancelled }
        if let inner = policy.carriedFailure { return containsCancellation(inner) }
    }
    if let concurrent = error as? any PrimaryFailureCarrying {
        return containsCancellation(concurrent.primaryFailure)
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

func decision(for rejection: Rejection) -> RetryDecision {
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

// MARK: - retry

/// Runs `operation`, retrying failures on `schedule`.
///
/// Before each retry, in order, `retry` stops and rethrows the last error if:
///
/// 1. the task running the retry was cancelled (a cancelled *attempt* — one
///    whose own timeout fired — is retried; a cancelled *caller* is not);
/// 2. this retry is nested inside another retry's attempt and `nesting` is
///    `.singleAttempt` (an attempt that timed out is still one attempt, and
///    the outer retry treats that timeout as transient);
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
    do throws(RetryStopped<Failure>) {
        return try await retryInline(
            schedule, budget: budget, classify: classify, nesting: nesting, clock: clock,
            label: label, fileID: fileID, line: line, operation: operation
        )
    } catch {
        throw error.lastError
    }
}

/// `retry` for an operation whose idempotency key was made with its intent
/// and outlives the process: an outbox entry's. Every attempt's key is
/// `idempotencyKey`, and so is the enclosing key of every operation started
/// inside one, so a keyed `perform` in an attempt derives the same key on
/// every attempt and every relaunch (design/22, Keys).
package nonisolated(nonsending) func retry<R, Failure: Error>(
    _ schedule: BoundedSchedule,
    idempotencyKey: IdempotencyKey,
    budget: RetryBudget = .perCallSite,
    classify: RetryClassifier<Failure> = .standard,
    label: String? = nil,
    fileID: String = #fileID,
    line: UInt = #line,
    operation: nonisolated(nonsending) (Attempt) async throws(Failure) -> R
) async throws(Failure) -> R {
    do throws(RetryStopped<Failure>) {
        return try await retryInline(
            schedule, budget: budget, classify: classify, nesting: .singleAttempt, clock: nil,
            label: label, fileID: fileID, line: line,
            identity: OperationIdentity(key: idempotencyKey, fileID: fileID, line: line), operation: operation
        )
    } catch {
        throw error.lastError
    }
}

/// The inline `retry`, saying why it stopped: what ``Retrying`` runs, so it
/// can report a stop that was a refusal as the rejection it is.
nonisolated(nonsending) func retryInline<R, Failure: Error>(
    _ schedule: BoundedSchedule,
    budget: RetryBudget,
    classify: RetryClassifier<Failure>,
    nesting: RetryNesting,
    clock: AnyClock?,
    label: String?,
    fileID: String,
    line: UInt,
    identity: OperationIdentity? = nil,
    operation: nonisolated(nonsending) (Attempt) async throws(Failure) -> R
) async throws(RetryStopped<Failure>) -> R {
    return try await retryLoop(
        schedule, budget: budget, classify: classify, nesting: nesting, clock: clock,
        label: label, fileID: fileID, line: line, identity: identity
    ) { attempt in
        await FaultPoint.hit("retry.attempt")
        let result: Result<R, Failure> = await attempt.operation.running(attempt: attempt.number) {
            do throws(Failure) {
                return .success(try await operation(attempt))
            } catch {
                return .failure(error)
            }
        }
        return (result, nestedAttemptTimedOut(attempt, result))
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
    do throws(RetryStopped<Failure>) {
        return try await retryLoop(
            schedule, budget: budget, classify: classify, nesting: nesting, clock: clock,
            label: label, fileID: fileID, line: line
        ) { attempt in
            let outcome = await attempt.operation.running(attempt: attempt.number) {
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
            return (outcome.result, outcome.expired || nestedAttemptTimedOut(attempt, outcome.result))
        }
    } catch {
        throw error.lastError
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
) async throws(RetryStopped<Failure>) -> R {
    let isolation = #isolation
    return try await retryLoop(
        schedule, budget: budget, classify: classify, nesting: nesting, clock: nil,
        label: label, fileID: fileID, line: line
    ) { attempt in
        // A local function, not a closure: `withoutActuallyEscaping`'s own
        // body is not `nonsending`, and the operation must stay on the
        // caller's actor.
        nonisolated(nonsending) func bounded(
            _ escapable: nonisolated(nonsending) @escaping () async throws(Failure) -> R
        ) async -> DeadlineOutcome<AttemptResult<R>, Failure> {
            await AttemptHandoff(escapable).runBounded(
                on: isolation, attempt: attempt, timeout: attemptTimeout,
                label: label.map { "\($0) attempt \(attempt.number)" }, fileID: fileID, line: line
            )
        }
        let outcome = await withoutActuallyEscaping(operation, do: bounded)
        // A closure, not a key path: a key path into a generic type is built
        // (and allocated) at run time on every evaluation.
        let result = outcome.result.map { $0.value }
        return (result, outcome.expired || nestedAttemptTimedOut(attempt, result))
    }
}

/// Runs one attempt of an operation that is not `Sendable` under a timer at
/// `deadline`, in a child task on the caller's actor (see
/// ``AttemptHandoff``): how a declared operation's `perform` bounds each
/// attempt.
///
/// - Parameters:
///   - enforced: Run the timer even when `deadline` does not narrow the one
///     in force, which then enforces nothing by itself.
///   - reportsExpiry: Report an enforced deadline's expiry as
///     `deadline.expired`: when the deadline is the caller's own, its scope
///     reports it instead.
///   - shielded: The caller's cancellation does not reach the attempt; only
///     the timer ends it early. For an attempt whose outcome is about to be
///     known and must not be made unknown by cutting it off (design/22,
///     Outcome).
nonisolated(nonsending) func runAttemptHandingOff<R, Failure: Error>(
    under deadline: Deadline,
    enforced: Bool,
    reportsExpiry: Bool,
    shielded: Bool,
    label: String?,
    fileID: String,
    line: UInt,
    operation: nonisolated(nonsending) () async throws(Failure) -> R
) async -> (result: Result<R, Failure>, expired: Bool) {
    let isolation = #isolation
    nonisolated(nonsending) func bounded(
        _ escapable: nonisolated(nonsending) @escaping () async throws(Failure) -> R
    ) async -> DeadlineOutcome<AttemptResult<R>, Failure> {
        let handoff = AttemptHandoff(escapable)
        guard shielded else {
            return await handoff.runUnder(deadline, enforced: enforced, reportsExpiry: reportsExpiry, on: isolation, label: label, fileID: fileID, line: line)
        }
        // Cancellation reaches every child task, shield or no shield, and a
        // shield inside the attempt would stop its timer too. So a shielded
        // attempt runs in a task of its own, which the caller's cancellation
        // does not reach, and the caller awaits it, shielded: it is never
        // left running.
        let attempt = Task.stoic {
            await handoff.runUnder(deadline, enforced: enforced, reportsExpiry: reportsExpiry, on: isolation, label: label, fileID: fileID, line: line)
        }
        return await withTaskCancellationShield { await attempt.value }
    }
    let outcome = await withoutActuallyEscaping(operation, do: bounded)
    return (outcome.result.map { $0.value }, outcome.expired)
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
        attempt: Attempt,
        timeout: Duration,
        label: String?,
        fileID: String,
        line: UInt
    ) async -> DeadlineOutcome<AttemptResult<R>, Failure> {
        await attempt.operation.running(attempt: attempt.number) {
            await runWithDeadline(.after(timeout, clock: nil), tolerance: nil, label: label, fileID: fileID, line: line) { () async throws(Failure) -> AttemptResult<R> in
                try await self.run(on: isolation)
            }
        }
    }

    /// Runs the operation under a timer at `deadline`, in the attempt the
    /// caller is already running.
    func runUnder(
        _ deadline: Deadline,
        enforced: Bool,
        reportsExpiry: Bool,
        on isolation: (any Actor)?,
        label: String?,
        fileID: String,
        line: UInt
    ) async -> DeadlineOutcome<AttemptResult<R>, Failure> {
        await runWithDeadline(
            deadline, tolerance: nil, label: label, fileID: fileID, line: line,
            enforced: enforced, reportsEnforcedExpiry: reportsExpiry
        ) { () async throws(Failure) -> AttemptResult<R> in
            try await self.run(on: isolation)
        }
    }

    private func run(on isolation: isolated (any Actor)?) async throws(Failure) -> AttemptResult<R> {
        AttemptResult(value: try await operation())
    }
}

/// Why a retry stopped, with the last attempt's error, which `retry` throws.
///
/// `retry` has only its operation's error type to throw, so it cannot say
/// that it stopped because its caller was cancelled, its budget ran dry or
/// the deadline left no room. ``Retrying``, whose error is ``PolicyError``,
/// can, and does: it reports those stops as the rejections they are.
struct RetryStopped<Failure: Error>: Error {
    typealias Reason = RetryStopReason

    let reason: Reason
    let lastError: Failure

    init(_ reason: Reason, _ lastError: Failure) {
        self.reason = reason
        self.lastError = lastError
    }
}

/// Why a retry, or a declared operation's retry loop, stopped.
enum RetryStopReason: Sendable {
    case cancelled
    case nested
    case permanent
    case exhausted
    /// The next attempt could not finish in time; the delay it needed.
    case deadline(Duration)
    case budgetExhausted
    /// An open breaker's wait was longer than the schedule's.
    case breakerOpen
    /// A declared operation inside the attempt gave up and settled it: it
    /// is not repeated, whatever the classifier says (design/22).
    case innerSettled
}

/// The most a server's `Retry-After` may delay a retry, whatever the device's
/// conditions (design/02): the cap is the last word, so a hot or low-power
/// device cannot stretch an hour-long wait to eight times that.
private let retryAfterCap = Duration.seconds(300)

/// What happens between two attempts, once a failure is worth retrying: the
/// schedule's delay or a server's wait, the device's stretch, the deadline,
/// the budget, and the sleep. `retry` and a declared operation's `perform`
/// both pace their retries with it, so the two cannot drift apart.
struct RetryPacer {
    /// What comes after a failure worth retrying.
    enum Pace {
        /// Sleep this long, having spent this token, then try again.
        case wait(Duration, BudgetStorage.Token?)
        /// Stop.
        case stop(RetryStopReason)
    }

    let ambient: Ambient
    let clock: AnyClock
    let schedule: BoundedSchedule
    let storage: BudgetStorage?
    let label: String?
    let fileID: String
    let line: UInt
    let start: AnyClock.Instant
    // Built on the first failure: most calls succeed at once and never need it.
    private var stepper: Schedule.Stepper?

    init(
        ambient: Ambient, clock: AnyClock, schedule: BoundedSchedule, storage: BudgetStorage?,
        label: String?, fileID: String, line: UInt
    ) {
        self.ambient = ambient
        self.clock = clock
        self.schedule = schedule
        self.storage = storage
        self.label = label
        self.fileID = fileID
        self.line = line
        self.start = clock.now
    }

    func report(_ name: EventName, _ fields: [Event.Field], level: Event.Level = .info) {
        ambient.instrumentation.record(Event(name, level: level, label: label, fields: fields, fileID: fileID, line: line))
    }

    /// Steps 4 to 6 of a retry (design/02) for attempt `number`'s failure,
    /// which the classifier said to retry with `decision`: the schedule, the
    /// deadline, the budget. Reports the decision either way.
    ///
    /// - Parameters:
    ///   - stretches: Whether a struggling device stretches the delay.
    ///   - sparesReserve: Whether the budget's last half reserve is kept
    ///     for someone who is waiting.
    mutating func pace(
        attempt number: Int, decision: RetryDecision, error: any Error, common: [Event.Field],
        attemptDuration: Duration, timedOut: Bool, stretches: Bool = true, sparesReserve: Bool = false
    ) -> Pace {
        let now = clock.now
        // 4. The schedule.
        if stepper == nil {
            stepper = schedule.makeStepper(random: ambient.random.generator(fileID: fileID, line: line))
        }
        guard let scheduled = stepper!.next(elapsed: start.duration(to: now)) else {
            report("retry.exhausted", common + [.init("elapsed", .duration(start.duration(to: now)))], level: .notice)
            return .stop(.exhausted)
        }
        var delay = scheduled
        var retryAfterCeiling: Duration?
        if case .retryAfter(let requested) = decision,
            let rejection = error.unwrappedForClassification as? Rejection, rejection.reason == .circuitOpen
        {
            // An open breaker said "fail fast". Wait it out only when that is
            // no longer than the schedule would wait anyway; every caller got
            // the same instant, so the wait is jittered upward (by up to a
            // tenth) to keep them from arriving at the half-open probe at once.
            if requested > scheduled {
                report("retry.breaker_open", common + [
                    .init("retry_after", .duration(requested)),
                    .init("scheduled", .duration(scheduled)),
                ], level: .notice)
                return .stop(.breakerOpen)
            }
            retryAfterCeiling = retryAfterCap
            delay = Self.jitteredUpward(requested, random: ambient.random, discriminator: UInt64(number), fileID: fileID, line: line)
        } else if case .retryAfter(let requested) = decision {
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
        let factor = stretches ? ambient.conditions.current.backoffFactor : 1
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
                return .stop(.deadline(delay))
            }
        }
        // 6. The budget.
        let token = storage?.withdraw(clock: clock, sparingReserve: sparesReserve)
        if storage != nil, token == nil {
            report("retry.budget_exhausted", common, level: .warning)
            return .stop(.budgetExhausted)
        }
        report("retry.attempt_failed", common + [
            .init("delay", .duration(delay)),
            .init("timed_out", .bool(timedOut)),
            .init("decision", .string(decision == .retry ? "retry" : "retry_after"), privacy: .public),
        ])
        return .wait(delay, token)
    }

    /// Sleeps `delay` on the clock. `false` when the caller was cancelled
    /// meanwhile: the last real failure is the answer, and the token goes
    /// back, since the retry it paid for never happens.
    func backoff(_ delay: Duration, token: BudgetStorage.Token?, common: [Event.Field]) async -> Bool {
        do {
            try await clock.sleep(until: clock.now.advanced(by: delay), tolerance: nil)
        } catch _ {
            if let storage, let token { storage.refund(token) }
            report("retry.cancelled", common, level: .debug)
            return false
        }
        if Task.isCancelled {
            if let storage, let token { storage.refund(token) }
            report("retry.cancelled", common, level: .debug)
            return false
        }
        return true
    }

    /// `duration` lengthened by up to a tenth, at random: a wait every
    /// caller was told at the same instant, spread so they do not all
    /// arrive together.
    static func jitteredUpward(
        _ duration: Duration, random: RandomSource, discriminator: UInt64, fileID: String, line: UInt
    ) -> Duration {
        var generator = random.generator(discriminator: discriminator, fileID: fileID, line: line)
        let fraction = Double(generator.next() >> 11) / Double(UInt64(1) << 53)
        let base = max(.zero, duration)
        return base.saturatingAdding(base.saturatingMultiplied(by: 0.1 * fraction))
    }
}

/// Whether `attempt` failed because a nested retry's own timer fired.
///
/// The nested retry made one attempt and rethrew the child's
/// `CancellationError`. That error is a timeout only when the nested retry
/// noted one, and only when the failure that left the operation is still
/// that cancellation: an operation that caught the timeout and threw
/// something else is classified as what it threw. The caller's own
/// cancellation is the loop's first check and never reaches this.
private func nestedAttemptTimedOut<R, Failure: Error>(_ attempt: Attempt, _ result: Result<R, Failure>) -> Bool {
    let noted = attempt.operation.takeAttemptTimedOut(attempt.number)
    guard noted, case .failure(let error) = result else { return false }
    return containsCancellation(error)
}

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
    identity: OperationIdentity? = nil,
    runAttempt: nonisolated(nonsending) (Attempt) async -> (result: Result<R, Failure>, timedOut: Bool)
) async throws(RetryStopped<Failure>) -> R {
    let ambient = Ambient.current
    let clock = explicitClock ?? ambient.clock
    let storage = budget.resolved(fileID: fileID, line: line, registry: ambient.budgets)
    // Started inside another operation's attempt, this retry is a
    // sub-operation of it: nested, and keyed from it. One whose key was
    // given is an operation of its own.
    let operation = identity ?? OperationIdentity.starting(fileID: fileID, line: line)
    let nested = operation.isSubOperation && nesting == .singleAttempt
    // A timeout an earlier nested retry threw, and this operation caught, must
    // not attach to whatever this one ends by throwing.
    if nested { operation.clearEnclosingAttemptTimedOut() }
    var pacer = RetryPacer(ambient: ambient, clock: clock, schedule: schedule, storage: storage, label: label, fileID: fileID, line: line)
    var number = 1

    storage?.deposit()

    while true {
        let attemptStart = clock.now
        let attempt = Attempt(number: number, elapsed: pacer.start.duration(to: attemptStart), operation: operation)
        let (result, timedOut) = await runAttempt(attempt)

        let error: Failure
        switch result {
        case .success(let value):
            if number > 1 {
                pacer.report("retry.succeeded", [.init("attempts", .int(number)), .init("elapsed", .duration(pacer.start.duration(to: clock.now)))])
            }
            return value
        case .failure(let failure):
            error = failure
        }

        let attemptDuration = attemptStart.duration(to: clock.now)
        let common: [Event.Field] = [.init("attempt", .int(number)), .init("error", .error(error))]

        // 0. A declared operation inside the attempt gave up on it: it is not
        // repeated, whatever follows says, and the layer outside learns so.
        if operation.isSettled(attempt: number) {
            operation.settleEnclosingAttempt()
            pacer.report("retry.stopped", common + [.init("reason", .string("inner_settled"), privacy: .public)])
            throw RetryStopped(.innerSettled, error)
        }
        // 1. The caller, not the attempt, was cancelled.
        if Task.isCancelled {
            pacer.report("retry.cancelled", common, level: .debug)
            throw RetryStopped(.cancelled, error)
        }
        // 2. Nested inside another retry: one attempt, and the layer outside
        // retries. An attempt that timed out is still that one attempt —
        // classifying it here would retry at this layer too — but the
        // timeout has to survive the rethrow. The error is the child's
        // `CancellationError`, which the outer classifier cannot tell from
        // the caller cancelling unless it is told the timer fired.
        if nested {
            if timedOut { operation.noteEnclosingAttemptTimedOut() }
            pacer.report("retry.nested", common, level: .notice)
            throw RetryStopped(.nested, error)
        }
        // 3. Classification.
        let decision = classify.decision(for: error, attemptTimedOut: timedOut)
        if decision == .stop {
            let defect = containsDefect(error)
            pacer.report(defect ? "retry.defect" : "retry.permanent", common, level: defect ? .error : .info)
            throw RetryStopped(.permanent, error)
        }
        // 4–6. The schedule, the deadline, the budget; then the wait.
        switch pacer.pace(attempt: number, decision: decision, error: error, common: common, attemptDuration: attemptDuration, timedOut: timedOut) {
        case .stop(let reason):
            throw RetryStopped(reason, error)
        case .wait(let delay, let token):
            guard await pacer.backoff(delay, token: token, common: common) else {
                throw RetryStopped(.cancelled, error)
            }
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
