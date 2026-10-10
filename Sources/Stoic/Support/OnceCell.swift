internal import Synchronization

/// A value set at most once, which any number of tasks can wait for.
///
/// The first `resolve` wins; later ones are ignored. Waiting is not
/// cancellation-aware: callers that need to stop waiting resolve the cell
/// themselves (from a cancellation handler or a timer).
final class OnceCell<Value: Sendable>: Sendable {
    private struct State {
        var value: Value?
        var waiters: [CheckedContinuation<Value, Never>] = []
    }

    private let state = Mutex(State())

    init() {}

    /// Sets the value if it is not set yet. Returns whether this call set it.
    @discardableResult
    func resolve(_ value: Value) -> Bool {
        let waiters = state.withLock { state -> [CheckedContinuation<Value, Never>]? in
            guard state.value == nil else { return nil }
            state.value = value
            defer { state.waiters = [] }
            return state.waiters
        }
        guard let waiters else { return false }
        for waiter in waiters { waiter.resume(returning: value) }
        return true
    }

    /// The value, once set.
    var value: Value {
        get async {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state -> Value? in
                    if let value = state.value { return value }
                    state.waiters.append(continuation)
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }
    }

    /// The value, if it is set.
    var current: Value? {
        state.withLock { $0.value }
    }
}
