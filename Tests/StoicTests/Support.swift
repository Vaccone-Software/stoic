import Foundation
import Synchronization

/// How much to multiply the size of every property and model test by.
/// The default keeps the suite fast; `STOIC_TEST_SCALE=20 swift test` hunts
/// harder, and a failure still names its seed.
let testScale: Int = {
    ProcessInfo.processInfo.environment["STOIC_TEST_SCALE"].flatMap(Int.init).map { max(1, $0) } ?? 1
}()

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

/// Whether `invariant` stays true for `window` of real time: the way to
/// assert that something does *not* happen. Use it only after a positive
/// signal that the thing would have happened by now if it were going to
/// (a gate that was opened, a task that was woken), and never in place of one.
func holdsThroughout(for window: Duration = .milliseconds(30), _ invariant: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let end = clock.now.advanced(by: window)
    while clock.now < end {
        if !invariant() { return false }
        try? await clock.sleep(for: .milliseconds(1))
    }
    return invariant()
}
