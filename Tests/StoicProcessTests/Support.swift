import Synchronization

/// A value shared between test tasks behind a lock.
final class SendableBox<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>

    init(_ value: Value) {
        storage = Mutex(value)
    }

    var value: Value {
        storage.withLock { $0 }
    }

    func mutate<R: Sendable>(_ body: (inout Value) -> R) -> R {
        storage.withLock { body(&$0) }
    }
}
