/// Who is waiting for the result of an operation.
///
/// The call's fact that an operation's policy is derived from, beside the
/// deadline (design/22): a person looking at a spinner gets two quick
/// attempts and a slot kept for people; a sync nobody watches gets patient
/// attempts, waits out an open breaker, and never takes the last half of a
/// backend's capacity. The app says who waits, never the numbers, as it
/// does with Apple's quality-of-service classes, which the cases mirror.
///
/// The cases are ordered by urgency, least first, so `min(_:_:)` caps one
/// urgency by another:
///
///     try await withUrgency(.interactive) {            // a tap
///         try await Catalogue.episode.perform { _ in try await api.episode(id) }
///     }
public enum Urgency: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// Nobody is waiting; minutes are fine.
    case background
    /// The result is shown eventually: a prefetch, a sync.
    case utility
    /// Someone asked and is waiting seconds.
    case userInitiated
    /// Someone is looking at a spinner.
    case interactive

    @TaskLocal static var stored: Urgency?

    /// The urgency of the current task: the innermost
    /// ``withUrgency(_:operation:)``, or, outside one, the urgency inferred
    /// from the task's base priority.
    ///
    /// The inference reads the *base* priority, not the escalated one, so a
    /// prefetch that a person later awaits keeps the policy it started with:
    /// `.background` is ``background``; `.utility` (which `.low` is) is
    /// ``utility``; anything higher, including `.medium`, the priority of a
    /// `Task {}` started off the main actor, is ``userInitiated``.
    /// ``interactive`` is never inferred: a call is interactive only when
    /// code says so.
    ///
    /// Child tasks, and every task Stoic starts, inherit an urgency set with
    /// `withUrgency`; a `Task.detached` starts without it, like any
    /// task-local, and infers its own.
    public static var current: Urgency {
        stored ?? inferred(from: Task.basePriority)
    }

    /// The urgency a base priority implies; `nil`, outside any task, is the
    /// default priority's.
    static func inferred(from priority: TaskPriority?) -> Urgency {
        guard let priority else { return .userInitiated }
        if priority <= .background { return .background }
        if priority <= .utility { return .utility }
        return .userInitiated
    }

    public var description: String {
        switch self {
        case .background: "background"
        case .utility: "utility"
        case .userInitiated: "userInitiated"
        case .interactive: "interactive"
        }
    }
}

/// Runs `operation` with `urgency` as ``Urgency/current``, for it and for
/// every task it starts.
///
/// Say who is waiting where that is known, at the root of the work: the tap
/// handler, the background refresh. Every operation performed beneath runs
/// at that urgency, capped by its own ceiling.
///
///     func open(_ id: Episode.ID) async throws {
///         episode = try await withUrgency(.interactive) {
///             try await Catalogue.episode.perform { _ in try await api.episode(id) }
///         }
///     }
///
/// The operation runs inline, on the caller's actor, and its error passes
/// through untouched.
public nonisolated(nonsending) func withUrgency<R, E: Error>(
    _ urgency: Urgency,
    operation: nonisolated(nonsending) () async throws(E) -> R
) async throws(E) -> R {
    try await Urgency.$stored.withValueTyped(urgency, operation: operation)
}
