import Synchronization

final class SendableBox<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>

    init(_ value: Value) { storage = Mutex(value) }

    var value: Value { storage.withLock { $0 } }

    func mutate(_ body: (inout Value) -> Void) { storage.withLock { body(&$0) } }
}

/// A one-shot gate that ignores cancellation: models work that cannot be interrupted.
final class Gate: Sendable {
    private let state = SendableBox<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.mutateReturning { state -> Bool in
                if state.open { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.mutateReturning { state -> [CheckedContinuation<Void, Never>] in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }
}

extension SendableBox {
    func mutateReturning<R>(_ body: (inout Value) -> R) -> R { storage.withLock { body(&$0) } }
}
