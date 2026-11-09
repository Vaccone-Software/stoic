#if os(macOS)
internal import Synchronization

/// A value set once, which any number of tasks wait for, each able to leave.
///
/// The first `open` wins. A waiter that is cancelled leaves at once with
/// `nil`, and the gate forgets it; the others keep waiting. A run's handshake
/// and its end are gates: many calls wait on each, and each call's own
/// deadline decides how long.
final class Gate<Value: Sendable>: Sendable {
    private struct State {
        var value: Value?
        var waiters: [UInt64: CheckedContinuation<Value?, Never>] = [:]
        var nextWaiter: UInt64 = 0
    }

    private let state = Mutex(State())

    init() {}

    /// Sets the value if it is not set yet. Returns whether this call set it.
    @discardableResult
    func open(_ value: Value) -> Bool {
        let waiters = state.withLock { state -> [CheckedContinuation<Value?, Never>]? in
            guard state.value == nil else { return nil }
            state.value = value
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        guard let waiters else { return false }
        for waiter in waiters { waiter.resume(returning: value) }
        return true
    }

    /// The value, if set.
    var value: Value? {
        state.withLock { $0.value }
    }

    /// The value, once set; `nil` if the waiting task is cancelled first.
    func wait() async -> Value? {
        let id = state.withLock { state in
            defer { state.nextWaiter += 1 }
            return state.nextWaiter
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
                let ready: Value?? = state.withLock { state in
                    if let value = state.value { return .some(value) }
                    if Task.isCancelled { return .some(nil) }
                    state.waiters[id] = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume(returning: nil)
        }
    }
}
#endif
