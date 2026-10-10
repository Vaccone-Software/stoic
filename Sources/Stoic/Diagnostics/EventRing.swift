internal import Synchronization

/// Keeps the most recent events in memory, for diagnostics.
///
/// When a user reports "it hung for a minute and then worked", the logs
/// that would explain it are usually gone or were never collected. A ring
/// keeps the last `capacity` decisions Stoic made — which retry slept, which
/// deadline passed, which child restarted — at a fixed memory cost, ready to
/// attach to a bug report through ``Diagnostics/snapshot(includePrivate:)``.
///
///     let ring = EventRing(capacity: 512)
///     withAmbient({ $0.instrumentation = CompositeInstrumentation([OSLogInstrumentation(), ring]) }) { … }
///
/// Recording is a constant-time append under a lock; the oldest event is
/// overwritten when the ring is full. Private fields stay private: the ring
/// holds events as recorded, and redaction is applied when they are
/// rendered for export.
public final class EventRing: Instrumentation, Sendable {
    public let capacity: Int

    private struct State {
        var slots: [Event?]
        var next = 0
        var total = 0
    }

    private let state: Mutex<State>

    public init(capacity: Int = 512) {
        precondition(capacity >= 1, "an event ring needs room for at least one event")
        self.capacity = capacity
        state = Mutex(State(slots: Array(repeating: nil, count: capacity)))
    }

    public func record(_ event: Event) {
        state.withLock { state in
            state.slots[state.next] = event
            state.next = (state.next + 1) % capacity
            state.total += 1
        }
    }

    /// The retained events, oldest first.
    public var events: [Event] {
        state.withLock { state in
            let ordered = state.slots[state.next...] + state.slots[..<state.next]
            return ordered.compactMap { $0 }
        }
    }

    /// How many events were recorded in all, including those overwritten.
    public var totalRecorded: Int {
        state.withLock { $0.total }
    }

    /// The process-wide ring, created by ``Diagnostics/install(capacity:)``.
    static let shared = Mutex<EventRing?>(nil)
}

/// A snapshot of what Stoic knows about the app's recent behaviour, for a
/// bug report or a support request.
public enum Diagnostics {
    /// Creates the process-wide ring that ``snapshot(includePrivate:)``
    /// reads, and returns it. Add it to the ambient instrumentation at launch:
    ///
    ///     let ring = Diagnostics.install()
    ///     try await withAmbient({ $0.instrumentation = CompositeInstrumentation([$0.instrumentation, ring]) }) {
    ///         try await app.run()
    ///     }
    @discardableResult
    public static func install(capacity: Int = 512) -> EventRing {
        let ring = EventRing(capacity: capacity)
        EventRing.shared.withLock { $0 = ring }
        return ring
    }

    /// The report: recent events (private fields redacted unless asked for)
    /// and the work currently abandoned.
    public static func snapshot(includePrivate: Bool = false) -> String {
        var lines: [String] = []
        let ring = EventRing.shared.withLock { $0 }
        if let ring {
            lines.append("Recent events (\(ring.events.count) of \(ring.totalRecorded) recorded):")
            for event in ring.events {
                lines.append("  " + render(event, includePrivate: includePrivate))
            }
        } else {
            lines.append("Recent events: no event ring installed (Diagnostics.install)")
        }
        let tasks = TaskLedger.current
        lines.append("Stoic tasks running: \(tasks.isEmpty ? "none" : "\(tasks.count)")")
        for task in tasks {
            lines.append("  \(task)")
        }
        let abandoned = AbandonedWork.current
        lines.append("Abandoned work: \(abandoned.isEmpty ? "none" : "")")
        for entry in abandoned {
            lines.append("  \(entry)")
        }
        return lines.joined(separator: "\n")
    }

    static func render(_ event: Event, includePrivate: Bool) -> String {
        var parts = ["\(event.level) \(event.name)"]
        if let label = event.label { parts.append("label=\(label)") }
        for field in event.fields {
            if field.privacy == .private && !includePrivate {
                parts.append("\(field.key)=<private>")
            } else {
                parts.append(field.description)
            }
        }
        parts.append("(\(event.fileID):\(event.line))")
        return parts.joined(separator: " ")
    }
}
