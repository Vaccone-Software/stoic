internal import Synchronization

/// Runs `operation` under a deadline, cancelling it if the deadline passes.
///
/// The deadline in force inside `operation` is the earlier of `deadline` and
/// the one already in force (``Deadline/current``); it is never widened.
/// Every Stoic primitive the operation calls honours it.
///
/// The deadline is cooperative, as in SE-0526. When it passes, the operation
/// is cancelled — with ``CancellationCause/deadline`` recorded — and
/// `withDeadline` waits for it to return. Its result or error passes through
/// unchanged: an operation that honours cancellation typically throws
/// `CancellationError`; one that finishes anyway returns its value. For work
/// that cannot be cancelled at all, see the abandoning timeout.
///
/// The operation runs as a child task, so the deadline can cancel it without
/// cancelling the caller. Like `Task {}`, the closure inherits the caller's
/// actor: written on the main actor, it runs on the main actor and may touch
/// main-actor state.
///
/// - Parameters:
///   - deadline: The instant by which the operation should finish.
///   - tolerance: Leeway for the underlying timer.
///   - label: Names the operation in events.
///   - fileID: The call site, captured for events.
///   - line: The call site, captured for events.
///   - operation: The work to run.
public nonisolated(nonsending) func withDeadline<R: Sendable, Failure: Error>(
    _ deadline: Deadline,
    tolerance: Duration? = nil,
    label: String? = nil,
    fileID: String = #fileID,
    line: UInt = #line,
    @_inheritActorContext operation: sending @escaping @isolated(any) () async throws(Failure) -> R
) async throws(Failure) -> R {
    try await runWithDeadline(deadline, tolerance: tolerance, label: label, fileID: fileID, line: line, operation: operation)
        .result.get()
}

/// The engine of ``withDeadline(_:tolerance:label:fileID:line:operation:)``,
/// reporting whether the deadline expired as well as the outcome, for
/// primitives (such as a retry's per-attempt timeout) that treat an expired
/// attempt differently from a failed one.
///
/// `enforced` runs a timer even for a deadline that does not narrow the one
/// in force: for a deadline nothing else enforces (`perform`'s default,
/// installed as ``Deadline/current`` without a scope of its own), or an
/// attempt shielded from the cancellation that would enforce it. Its expiry
/// is reported when it narrows, or when `reportsEnforcedExpiry` says no
/// scope of its own will.
nonisolated(nonsending) func runWithDeadline<R: Sendable, Failure: Error>(
    _ deadline: Deadline,
    tolerance: Duration?,
    label: String?,
    fileID: String,
    line: UInt,
    enforced: Bool = false,
    reportsEnforcedExpiry: Bool = false,
    @_inheritActorContext operation: sending @escaping @isolated(any) () async throws(Failure) -> R
) async -> DeadlineOutcome<R, Failure> {
    // A deadline that cannot narrow the one in force is a no-op: the
    // enclosing scope's timer cancels the operation, and that scope reports
    // the expiry under its own label. A second timer here would only add a
    // task group, a sleeper and a duplicate `deadline.expired` naming the
    // wrong scope, and tell a retry its attempt timed out when the whole
    // call ran out of time.
    let inherited = Deadline.current
    let narrows = inherited.map { deadline.isEarlier(than: $0) } ?? true
    if !narrows, !enforced, let inherited, !inherited.hasPassed {
        do throws(Failure) {
            return DeadlineOutcome(result: .success(try await operation()), expired: false)
        } catch {
            return DeadlineOutcome(result: .failure(error), expired: false)
        }
    }

    let effective = deadline.narrowedByCurrent
    let started = effective.clock.now
    // Read once: a deadline that passes between two reads must not count as
    // passed on entry without the operation having been cancelled for it.
    let passedOnEntry = effective.hasPassed
    let cause = CancellationCauseBox()
    let slot = OperationSlot(operation)
    // The operation's one child task does an attempt's work, if it runs in
    // one: a `perform` inside it is in the attempt's task, not a child of it.
    let attempt = RetryContext.active

    let outcome: DeadlineOutcome<R, Failure> = await Deadline.$stored.withValue(effective) {
            await withTaskGroup(of: DeadlineChild<R, Failure>.self) { group in
                if passedOnEntry {
                    cause.record(.deadline)
                    group.cancelAll()
                }
                group.addTask {
                    await CancellationCauseBox.$current.withValue(cause) {
                        guard let attempt else { return await slot.run() }
                        return await RetryContext.$active.withValue(attempt.carried()) { await slot.run() }
                    }
                }
                group.addTask {
                    do {
                        try await effective.clock.sleep(until: effective.instant, tolerance: tolerance)
                        return .timerFired
                    } catch {
                        return .timerCancelled
                    }
                }
                var result: Result<R, Failure>?
                var expired = passedOnEntry
                while let child = await group.next() {
                    switch child {
                    case .finished(let finished):
                        result = finished
                        group.cancelAll()
                    case .timerFired:
                        if result == nil {
                            expired = true
                            cause.record(.deadline)
                            group.cancelAll()
                        }
                    case .timerCancelled:
                        break
                    }
                }
                guard let result else {
                    preconditionFailure("withDeadline: the operation's child task produced no result")
                }
                return DeadlineOutcome(result: result, expired: expired)
            }
    }

    // Entered after an enclosing deadline had passed: the operation ran
    // cancelled, as on entry to any passed deadline, but the expiry is the
    // enclosing scope's to report.
    guard narrows || enforced && reportsEnforcedExpiry else {
        return DeadlineOutcome(result: outcome.result, expired: enforced && outcome.expired)
    }
    if outcome.expired {
        let finished = effective.clock.now
        Ambient.record(Event("deadline.expired", level: .notice, label: label, fields: [
            .init("budget", .duration(started.duration(to: effective.instant))),
            .init("overrun", .duration(max(.zero, effective.instant.duration(to: finished)))),
            .init("outcome", .string(outcome.result.isSuccess ? "returned" : "threw"), privacy: .public),
        ], fileID: fileID, line: line))
    }
    return outcome
}

/// Runs `operation` with a timeout: a deadline `duration` from now.
///
/// Identical to ``withDeadline(_:tolerance:label:fileID:line:operation:)``
/// with `.after(duration)`, including the deadline's cooperative semantics.
public nonisolated(nonsending) func withTimeout<R: Sendable, Failure: Error>(
    _ duration: Duration,
    clock: AnyClock? = nil,
    tolerance: Duration? = nil,
    label: String? = nil,
    fileID: String = #fileID,
    line: UInt = #line,
    @_inheritActorContext operation: sending @escaping @isolated(any) () async throws(Failure) -> R
) async throws(Failure) -> R {
    try await withDeadline(
        .after(duration, clock: clock),
        tolerance: tolerance,
        label: label,
        fileID: fileID,
        line: line,
        operation: operation
    )
}

private enum DeadlineChild<R: Sendable, Failure: Error>: Sendable {
    case finished(Result<R, Failure>)
    case timerFired
    case timerCancelled
}

struct DeadlineOutcome<R: Sendable, Failure: Error>: Sendable {
    let result: Result<R, Failure>
    let expired: Bool
}

/// Hands a `sending` operation to exactly one child task.
///
/// A `sending` closure cannot be captured by a task group's body and then
/// sent again to `addTask`: the compiler cannot prove the body does not keep
/// using it. Moving it into a mutex first makes the transfer explicit — the
/// child takes it out, once, and nothing else can reach it.
final class OperationSlot<R: Sendable, Failure: Error>: Sendable {
    typealias Operation = @isolated(any) () async throws(Failure) -> R

    private let operation: Mutex<Operation?>

    init(_ operation: sending @escaping Operation) {
        self.operation = Mutex(operation)
    }

    /// Runs the operation, which must not have run before.
    fileprivate func run() async -> DeadlineChild<R, Failure> {
        .finished(await runResult())
    }

    /// Runs the operation and captures its outcome as a value.
    func runResult() async -> Result<R, Failure> {
        let taken = operation.withLock { $0.take() }
        guard let taken else {
            preconditionFailure("OperationSlot: the operation was already taken")
        }
        do throws(Failure) {
            return .success(try await taken())
        } catch {
            return .failure(error)
        }
    }
}

extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
