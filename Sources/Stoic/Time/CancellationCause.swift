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
    /// The system is ending the time it granted, or will not grant it: a
    /// background task expired or was refused, or the app is being suspended.
    public static let systemExpiring = CancellationCause(rawValue: "system_expiring")
    /// The scope that owned it ended.
    public static let scopeEnded = CancellationCause(rawValue: "scope_ended")
    /// The supervisor that owned it stopped it.
    public static let supervisorStopped = CancellationCause(rawValue: "supervisor_stopped")

    public var description: String { rawValue }

    /// Why the current task was cancelled, or `nil` if it was not — except
    /// a refusal of background time, which is reported here without the
    /// task being cancelled.
    ///
    /// Stoic records a cause before every cancellation it initiates, in the
    /// task it cancels; nested Stoic scopes consult their enclosing scopes in
    /// turn. Cancellation that no Stoic scope initiated — a caller cancelling
    /// its task, a view disappearing — reads as ``userRequested``, the same
    /// default SE-0526 gives `CancellationError.Reason`.
    ///
    /// A host that was refused background time throws `CancellationError`
    /// and does not cancel the caller: cancellation is irrevocable, and the
    /// caller has to keep running to tell the refusal from a flush that
    /// finished. The cause (``systemExpiring``) is recorded for that caller
    /// and reported here while they handle the error, then dropped, so a
    /// later task cannot observe it. A task that is already cancelled keeps
    /// the cause it already had.
    public static var current: CancellationCause? {
        if Task.isCancelled {
            // A real cancellation wins over a refusal recorded for this task.
            RefusalSignal.clearCurrentTask()
            return CancellationCauseBox.current?.resolvedCause ?? .userRequested
        }
        return RefusalSignal.current
    }
}

/// A `.systemExpiring` cause thrown at the caller without cancelling them.
///
/// The caller's task must stay alive — cancelling it would stick — so the
/// cause cannot live only in the box of a child that has already ended.
/// It is recorded in its own box and held, keyed by the task, until the
/// handler has had the turn it was thrown on, or the task is cancelled.
enum RefusalSignal {
    private struct Entry {
        let nonce: UInt64
        let box: CancellationCauseBox
    }

    private static let signals = Mutex<[Int: Entry]>([:])
    private static let nonces = Atomic<UInt64>(0)
    /// How many tasks currently hold a refusal. ``CancellationCause/current``
    /// loads this and returns immediately when it is zero, which is the
    /// common path.
    private static let armed = Atomic<Int>(0)

    /// The refusal recorded for the current task, if it still holds one.
    static var current: CancellationCause? {
        guard armed.load(ordering: .acquiring) != 0, let id = taskIdentity else { return nil }
        return signals.withLock { $0[id]?.box.cause }
    }

    /// Records `.systemExpiring` for the current task and drops it on the
    /// next turn, after the caller's handler has read it, so a dead task's
    /// hash cannot be read as a refusal by a task that reused it.
    static func arm() {
        guard let id = taskIdentity else { return }
        let box = CancellationCauseBox(parent: CancellationCauseBox.current)
        box.record(.systemExpiring)
        let nonce = nonces.wrappingAdd(1, ordering: .relaxed).newValue
        let inserted = signals.withLock { map -> Bool in
            let isNew = map[id] == nil
            map[id] = Entry(nonce: nonce, box: box)
            return isNew
        }
        if inserted { _ = armed.wrappingAdd(1, ordering: .acquiringAndReleasing) }
        // Yields once before removing, so the caller's synchronous handler
        // observes the cause first. Runs on the ambient executor when a
        // simulation set one; otherwise it is an ordinary task that only
        // yields.
        Task.stoic {
            await Task.yield()
            let removed = signals.withLock { map -> Bool in
                guard map[id]?.nonce == nonce else { return false }
                map[id] = nil
                return true
            }
            if removed { _ = armed.wrappingSubtract(1, ordering: .acquiringAndReleasing) }
        }
    }

    /// Drops whatever refusal the current task holds.
    static func clearCurrentTask() {
        guard armed.load(ordering: .acquiring) != 0, let id = taskIdentity else { return }
        let removed = signals.withLock { $0.removeValue(forKey: id) != nil }
        if removed { _ = armed.wrappingSubtract(1, ordering: .acquiringAndReleasing) }
    }

    /// The identity of the current task, or `nil` outside one.
    private static var taskIdentity: Int? {
        // Unsafe, justified: the task is hashed and nothing else; it is not
        // retained, resumed or used past the closure. The hash is unique
        // among tasks alive at once. The entry is removed on the task's next
        // turn, or when the task is cancelled, so a hash reused later does
        // not still name this refusal.
        unsafe withUnsafeCurrentTask { task in unsafe task?.hashValue }
    }
}

/// The cell Stoic writes a cause into before it cancels a task it started.
/// Installed as a task-local in that task, so the task can read its own cause.
final class CancellationCauseBox: Sendable {
    private let storage = Mutex<CancellationCause?>(nil)

    /// The box of the enclosing Stoic scope, when this one is nested.
    let parent: CancellationCauseBox?

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

    /// The cause of a cancellation that reached a task from outside, as a
    /// cancellation handler in it should record it: the cause the nearest
    /// enclosing Stoic scope (`box` and its parents) recorded before it
    /// cancelled, and ``CancellationCause/userRequested`` only when none did.
    ///
    /// A handler that records `.userRequested` outright hides the real
    /// cause: inside a scope under an expiring deadline, the scope's work
    /// would read "the user cancelled" and every policy in it would answer
    /// `.cancelled` instead of `.deadlineExceeded`.
    static func outsideCause(seenBy box: CancellationCauseBox?) -> CancellationCause {
        box?.resolvedCause ?? .userRequested
    }
}
