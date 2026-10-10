internal import Synchronization

/// Why Stoic cancelled the current task.
///
/// Swift's cancellation is a single bit: a task learns that it was cancelled,
/// never why. When Stoic cancels work it started — a deadline passed, a newer
/// request superseded it, its scope ended — it records the cause first, so
/// the work (and the error report that follows) can tell a timeout from a
/// user pressing Cancel. When SE-0526 ships, this maps onto
/// `Task.cancellationReason`.
public struct CancellationCause: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// A deadline or timeout passed.
    public static let deadline = CancellationCause(rawValue: "deadline")
    /// The work's caller was cancelled.
    public static let userRequested = CancellationCause(rawValue: "user_requested")
    /// Newer work replaced it, as in a ``TaskSlot`` or a race that was won.
    public static let superseded = CancellationCause(rawValue: "superseded")
    /// A sibling failed, and the group it belonged to stopped.
    public static let siblingFailed = CancellationCause(rawValue: "sibling_failed")
    /// The system is ending the time it granted: a background task expired,
    /// or the app is being suspended.
    public static let systemExpiring = CancellationCause(rawValue: "system_expiring")
    /// The scope that owned it ended.
    public static let scopeEnded = CancellationCause(rawValue: "scope_ended")
    /// The supervisor that owned it stopped it.
    public static let supervisorStopped = CancellationCause(rawValue: "supervisor_stopped")

    public var description: String { rawValue }

    /// Why the current task was cancelled, or `nil` if it was not.
    ///
    /// Stoic records a cause before every cancellation it initiates, in the
    /// task it cancels; nested Stoic scopes consult their enclosing scopes in
    /// turn. Cancellation that no Stoic scope initiated — a caller cancelling
    /// its task, a view disappearing — reads as ``userRequested``, the same
    /// default SE-0526 gives `CancellationError.Reason`.
    public static var current: CancellationCause? {
        guard Task.isCancelled else { return nil }
        return CancellationCauseBox.current?.resolvedCause ?? .userRequested
    }
}

/// The cell Stoic writes a cause into before it cancels a task it started.
/// Installed as a task-local in that task, so the task can read its own cause.
final class CancellationCauseBox: Sendable {
    private let storage = Mutex<CancellationCause?>(nil)

    /// The box of the enclosing Stoic scope, when this one is nested.
    private let parent: CancellationCauseBox?

    @TaskLocal static var current: CancellationCauseBox?

    /// A box nested in the current task's box, if it has one.
    init(parent: CancellationCauseBox? = CancellationCauseBox.current) {
        self.parent = parent
    }

    var cause: CancellationCause? {
        storage.withLock { $0 }
    }

    /// This scope's cause, or the nearest enclosing scope's.
    var resolvedCause: CancellationCause? {
        cause ?? parent?.resolvedCause
    }

    /// Records `cause` unless a cause is already recorded: the first reason
    /// a task was cancelled is the reason.
    func record(_ cause: CancellationCause) {
        storage.withLock { stored in
            if stored == nil { stored = cause }
        }
    }
}
