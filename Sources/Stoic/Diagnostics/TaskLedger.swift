internal import Synchronization

/// Every long-lived task Stoic has started and that is still running.
///
/// The goroutine dump Swift lacks. When an app hangs, the question is "what
/// is everything waiting on?" — and the unstructured work that libraries
/// start (a request superseded but still winding down, a supervisor's child,
/// a state's work) is exactly what no debugger view lists. Stoic registers
/// every such task here with its kind, its label and when it started, so
/// ``Diagnostics/snapshot(includePrivate:)`` can list them and a test can
/// assert that nothing was left running (`StoicTesting`'s
/// `expectQuiescent`).
public enum TaskLedger {
    /// What kind of Stoic primitive started a task.
    public enum Kind: String, Sendable, Hashable {
        case slot, fork, scopeBody, supervisorChild, stateWork, stateTimeout, flight
    }

    /// One running task.
    public struct Entry: Sendable, CustomStringConvertible {
        public let kind: Kind
        public let label: String?
        public let startedAt: ContinuousClock.Instant
        let tag: UInt64?

        public var age: Duration { startedAt.duration(to: .now) }

        public var description: String {
            "\(kind.rawValue)\(label.map { " \($0)" } ?? "") running for \(age)"
        }
    }

    private struct State {
        var nextID: UInt64 = 0
        var entries: [UInt64: Entry] = [:]
    }

    private static let state = Mutex(State())

    /// Every Stoic-owned task running now, oldest first.
    public static var current: [Entry] {
        state.withLock { Array($0.entries.values) }.sorted { $0.startedAt < $1.startedAt }
    }

    /// The running tasks started under `tag` (see ``Ambient/ledgerTag``).
    public static func entries(tag: UInt64) -> [Entry] {
        current.filter { $0.tag == tag }
    }

    /// Starts `operation` as a task registered for as long as it runs.
    /// Like `Task {}`, the closure inherits the caller's actor.
    static func task<T: Sendable>(
        _ kind: Kind,
        label: String?,
        @_inheritActorContext operation: sending @escaping @isolated(any) () async -> T
    ) -> Task<T, Never> {
        let entry = Entry(kind: kind, label: label, startedAt: .now, tag: Ambient.current.ledgerTag)
        let id = state.withLock { state -> UInt64 in
            defer { state.nextID += 1 }
            state.entries[state.nextID] = entry
            return state.nextID
        }
        return Task {
            defer { _ = state.withLock { $0.entries.removeValue(forKey: id) } }
            return await operation()
        }
    }
}
