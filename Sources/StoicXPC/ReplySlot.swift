#if os(macOS)
internal import Synchronization

/// Where one attempt waits for its reply: settled exactly once, by the
/// reply, by the loss of its run, or by the attempt's cancellation —
/// whichever comes first. A later settlement is refused, and the caller of
/// `settle` learns so (a late reply is reported).
///
/// XPC's own `cancel` does not fail a pending reply (design/25, Origin), so
/// a call that waited for XPC to give up would wait out a wedged handler. It
/// waits for this instead.
final class ReplySlot<Value: Sendable>: Sendable {
    private enum State {
        /// Nobody waits yet, and nothing has settled it.
        case empty
        /// Settled before anyone waited: a fast reply, or a cancellation
        /// before the wait began.
        case early(Value)
        case waiting(CheckedContinuation<Value, Never>)
        case done
    }

    private let state = Mutex(State.empty)

    init() {}

    /// Waits for the value. `cancelled` is the value when the waiting task
    /// is cancelled first, already or later. Call it once.
    func wait(cancelled: @escaping @Sendable () -> Value) async -> Value {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
                let early: Value? = state.withLock { state in
                    switch state {
                    case .empty:
                        state = .waiting(continuation)
                        return nil
                    case .early(let value):
                        state = .done
                        return value
                    case .waiting, .done:
                        preconditionFailure("a reply slot is waited on once")
                    }
                }
                if let early { continuation.resume(returning: early) }
            }
        } onCancel: {
            settle(cancelled())
        }
    }

    /// Settles the slot. Returns false if it was settled already.
    @discardableResult
    func settle(_ value: Value) -> Bool {
        let outcome: (settled: Bool, continuation: CheckedContinuation<Value, Never>?) = state.withLock { state in
            switch state {
            case .empty:
                state = .early(value)
                return (true, nil)
            case .waiting(let continuation):
                state = .done
                return (true, continuation)
            case .early, .done:
                return (false, nil)
            }
        }
        outcome.continuation?.resume(returning: value)
        return outcome.settled
    }
}
#endif
