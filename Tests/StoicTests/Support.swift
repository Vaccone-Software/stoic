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

/// Polls `condition` until it holds or `limit` of real time passes. For
/// waiting on work that runs on other tasks, where a fixed number of yields
/// is not enough under load.
@discardableResult
func eventually(within limit: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: limit)
    while !condition() {
        if clock.now >= deadline { return false }
        try? await clock.sleep(for: .milliseconds(1))
    }
    return true
}
