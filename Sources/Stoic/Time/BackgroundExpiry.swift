internal import Synchronization

/// Runs work within time that a host system grants and can take back.
///
/// The engine of the UIKit background-work bridge, public so other hosts
/// (a BGTask handler, an app extension, a helper process told to wind down)
/// can do the same. Each ``run(within:label:_:)``:
///
/// - runs `work` under a ``Deadline`` of the time granted, so every retry,
///   wait and timeout inside it knows how long it has, and is cancelled
///   (cause ``CancellationCause/deadline``) when that time is up;
/// - is cancelled with cause ``CancellationCause/systemExpiring`` when the
///   host calls ``expire()``, so cleanup can tell "the system took our time
///   away" from "the user cancelled";
/// - is cancelled when its caller is, like any child work.
///
/// Expiry is final: once the host has taken the time back, later runs are
/// refused at once with the same cause.
public final class ExpiringWork: Sendable {
    private struct State {
        var expired = false
        var nextID: UInt64 = 0
        var running: [UInt64: Run] = [:]
    }

    private struct Run {
        let cause: CancellationCauseBox
        let cancel: @Sendable () -> Void
    }

    private let state = Mutex(State())

    public init() {}

    /// Whether ``expire()`` has been called.
    public var isExpired: Bool {
        state.withLock { $0.expired }
    }

    /// Runs `work` until it finishes, its time is up, the host expires it,
    /// or the caller is cancelled.
    ///
    /// - Parameters:
    ///   - limit: The time granted, if the host says; `nil` for none beyond
    ///     the caller's own deadline.
    ///   - label: Names the work in events.
    ///   - work: The work.
    /// - Throws: `work`'s error; `CancellationError` when cut short, with
    ///   ``CancellationCause/current`` saying why inside `work`.
    public func run<R: Sendable>(
        within limit: Duration? = nil,
        label: String? = nil,
        _ work: @escaping @Sendable () async throws -> R
    ) async throws -> R {
        // Its own cause per run: one run's expiry or cancellation must not
        // be read as another's. Nested in the caller's, so a caller's
        // recorded cause is what the work sees when the caller is cancelled.
        if isExpired { throw CancellationError() }
        let cause = CancellationCauseBox(parent: CancellationCauseBox.current)
        let task = Task {
            try await CancellationCauseBox.$current.withValue(cause) {
                if let limit {
                    try await withTimeout(limit, label: label) { try await work() }
                } else {
                    try await work()
                }
            }
        }
        let id = state.withLock { state -> UInt64? in
            if state.expired { return nil }
            defer { state.nextID += 1 }
            state.running[state.nextID] = Run(cause: cause, cancel: { task.cancel() })
            return state.nextID
        }
        guard let id else {
            // Expired between the check and now: the work starts cancelled.
            cause.record(.systemExpiring)
            task.cancel()
            _ = await task.result
            throw CancellationError()
        }
        defer { _ = state.withLock { $0.running.removeValue(forKey: id) } }
        // Awaiting a task's value does not pass cancellation on: say so.
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Takes the time back: every running piece of work is cancelled with
    /// cause ``CancellationCause/systemExpiring``, and later runs are
    /// refused. Returns without waiting for the work to stop.
    public func expire() {
        let runs = state.withLock { state -> [Run] in
            state.expired = true
            return Array(state.running.values)
        }
        for run in runs {
            run.cause.record(.systemExpiring)
            run.cancel()
        }
    }

    /// The time a host reports as remaining, as a limit for
    /// ``run(within:label:_:)``: `nil` when it is not a usable duration.
    ///
    /// UIKit reports `Double.greatestFiniteMagnitude` while the app is in the
    /// foreground — finite, but no duration can hold it — and anything above
    /// an hour is treated the same way: not a grant, just "no limit yet".
    public static func limit(fromSecondsRemaining seconds: Double) -> Duration? {
        guard seconds.isFinite, seconds > 0, seconds <= 3600 else { return nil }
        return .milliseconds(Int64((seconds * 1000).rounded(.down)))
    }
}
