public import Stoic
internal import Synchronization

/// Keeps every event, for tests to assert on.
public final class RecordingInstrumentation: Instrumentation, Sendable {
    private let recorded = Mutex<[Event]>([])

    public init() {}

    public func record(_ event: Event) {
        recorded.withLock { $0.append(event) }
    }

    /// Every event so far, in the order recorded.
    public var events: [Event] {
        recorded.withLock { $0 }
    }

    /// The events with `name`.
    public func events(named name: EventName) -> [Event] {
        events.filter { $0.name == name }
    }

    /// The names of every event so far, in order.
    public var names: [EventName] {
        events.map(\.name)
    }

    /// Forgets every event so far.
    public func reset() {
        recorded.withLock { $0.removeAll() }
    }
}
