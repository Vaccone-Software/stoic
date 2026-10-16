internal import Synchronization

/// Something an app depends on — a server, a system service, a local store,
/// on-device compute — declared once, as a value.
///
/// A backend holds two facts and no other number: what it is, and how much
/// concurrent work it can take. Its operations are declared on it with one
/// factory per repeat safety, and `perform` derives every resilience number
/// from those facts and the call's own (who is waiting, by when): the
/// retries, the attempt timeout, the breaker, the admission and the budget
/// (design/22). Its state — breaker, bulkhead, budget — lives in the ambient
/// context, keyed by name, so a test starts with a fresh one.
///
///     extension Backend {
///         static let catalogue = Backend.remote("catalogue")
///         static let library = Backend.local("library.sqlite")
///     }
///
///     enum Catalogue {
///         static let episode = Backend.catalogue.readOnly("episode")
///         static let download = Backend.catalogue.idempotent("download", length: .long)
///     }
///
/// The name is the identity: equality and hashing use it alone. Two
/// declarations of one name with a different kind or capacity are a bug,
/// reported as `operation.backend_conflict` at error level; the first
/// declaration in the process wins, and nothing crashes.
public struct Backend: Sendable, Hashable, CustomStringConvertible {
    /// What a backend is: what its failures mean, and so how it is retried
    /// and guarded.
    public enum Kind: Sendable, Hashable, CustomStringConvertible {
        /// A server, over a network.
        case remote
        /// An XPC service, a daemon, an OS framework call.
        case system
        /// A database or a file on this device.
        case local
        /// On-device inference or other heavy local work.
        case compute

        public var description: String {
            switch self {
            case .remote: "remote"
            case .system: "system"
            case .local: "local"
            case .compute: "compute"
            }
        }
    }

    /// The backend's identity, and the label of its state and events.
    public let name: String

    /// What the backend is.
    public let kind: Kind

    /// The most operations in flight on it at once.
    public let capacity: Int

    private init(name: String, kind: Kind, capacity: Int) {
        self.name = name
        self.kind = kind
        self.capacity = capacity
    }

    /// A server, reached over a network. Six at a time by default, as
    /// browsers allow per host.
    public static func remote(_ name: String, capacity: Int = 6) -> Backend {
        declare(name, kind: .remote, capacity: capacity)
    }

    /// An XPC service, a daemon or an OS framework call. Four at a time by
    /// default.
    public static func system(_ name: String, capacity: Int = 4) -> Backend {
        declare(name, kind: .system, capacity: capacity)
    }

    /// A database or file on this device. Four at a time by default; of
    /// those, one operation that is not `.readOnly` at a time (design/22,
    /// Writers).
    public static func local(_ name: String, capacity: Int = 4) -> Backend {
        declare(name, kind: .local, capacity: capacity)
    }

    /// On-device inference or other heavy local work. One at a time by
    /// default: a second inference only competes with the first.
    public static func compute(_ name: String, capacity: Int = 1) -> Backend {
        declare(name, kind: .compute, capacity: capacity)
    }

    /// An operation that changes nothing: a fetch, a query.
    public func readOnly(_ name: String, length: Operation.Length = .brief, ceiling: Urgency = .interactive) -> Operation {
        Operation(backend: self, name: name, safety: .readOnly, length: length, ceiling: ceiling)
    }

    /// An operation that leaves the same result run twice as once: a `PUT`
    /// of a whole value, a delete by identifier.
    public func idempotent(_ name: String, length: Operation.Length = .brief, ceiling: Urgency = .interactive) -> Operation {
        Operation(backend: self, name: name, safety: .idempotent, length: length, ceiling: ceiling)
    }

    /// An operation repeatable only because the backend deduplicates it by
    /// key: send `attempt.idempotencyKey` with every attempt.
    public func keyed(_ name: String, length: Operation.Length = .brief, ceiling: Urgency = .interactive) -> Operation {
        Operation(backend: self, name: name, safety: .keyed, length: length, ceiling: ceiling)
    }

    /// An operation that may repeat its effect if run again: it is retried
    /// only when a failure proves nothing reached the backend.
    public func notRepeatable(_ name: String, length: Operation.Length = .brief, ceiling: Urgency = .interactive) -> Operation {
        Operation(backend: self, name: name, safety: .notRepeatable, length: length, ceiling: ceiling)
    }

    public static func == (lhs: Backend, rhs: Backend) -> Bool {
        lhs.name == rhs.name
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }

    public var description: String {
        "\(kind)(\(name), capacity \(capacity))"
    }

    // MARK: The declaration table

    /// Every backend name declared in the process, with its kind and
    /// capacity: independent of the ambient registry and of tests, so a
    /// conflict is found wherever the two declarations are made.
    private static let declarations = Mutex<[String: (kind: Kind, capacity: Int)]>([:])

    /// The backend `name`, as first declared in the process.
    private static func declare(_ name: String, kind: Kind, capacity: Int) -> Backend {
        precondition(capacity >= 1, "backend \(name): capacity must be at least one")
        let first = declarations.withLock { declarations -> (kind: Kind, capacity: Int) in
            if let first = declarations[name] { return first }
            declarations[name] = (kind, capacity)
            return (kind, capacity)
        }
        if first.kind != kind || first.capacity != capacity {
            Ambient.record(Event("operation.backend_conflict", level: .error, label: name, fields: [
                .init("backend", .string(name), privacy: .public),
                .init("kind", .string(kind.description), privacy: .public),
                .init("capacity", .int(capacity)),
            ]))
        }
        return Backend(name: name, kind: first.kind, capacity: first.capacity)
    }
}

/// Whether running an operation more than once is harmless: the fact that
/// decides whether, and on what proof, it is retried.
public enum RepeatSafety: Sendable, Hashable, CustomStringConvertible {
    /// It changes nothing.
    case readOnly
    /// Twice leaves what once leaves.
    case idempotent
    /// Repeatable because the backend deduplicates by
    /// `attempt.idempotencyKey`, sent on every attempt.
    case keyed
    /// Repeating it may repeat its effect.
    case notRepeatable

    public var description: String {
        switch self {
        case .readOnly: "readOnly"
        case .idempotent: "idempotent"
        case .keyed: "keyed"
        case .notRepeatable: "notRepeatable"
        }
    }
}

extension Backend {
    /// One operation on a backend: a value, declared once, as a
    /// `static let`, with one of the backend's factories.
    ///
    /// The declaration holds what the operation knows about itself: its
    /// repeat safety, whether it is a brief call or a long transfer, and the
    /// highest urgency it may run at. Everything else is derived for each
    /// call by ``perform(idempotencyKey:fileID:line:operation:)``; a call
    /// site cannot set a number.
    ///
    ///     enum Payments {
    ///         static let subscribe = Backend.payments.keyed("subscribe")
    ///     }
    ///
    ///     let receipt = try await Payments.subscribe.perform(idempotencyKey: checkout.key) { attempt in
    ///         try await api.subscribe(plan, idempotencyKey: attempt.idempotencyKey)
    ///     }
    public struct Operation: Sendable, Hashable, CustomStringConvertible {
        /// How long one attempt is expected to take.
        public enum Length: Sendable, Hashable, CustomStringConvertible {
            /// A request, a query: an attempt that runs long is stuck.
            case brief
            /// A transfer, a migration: slow is not stuck.
            case long

            public var description: String {
                switch self {
                case .brief: "brief"
                case .long: "long"
                }
            }
        }

        /// The backend it calls.
        public let backend: Backend

        /// Its name, unique on its backend.
        public let name: String

        /// Whether running it twice is harmless.
        public let safety: RepeatSafety

        /// Whether it is a brief call or a long one.
        public let length: Length

        /// The highest urgency it runs at, however it is called: a bulk
        /// re-index declared with a `.utility` ceiling never claims the
        /// capacity kept for people.
        public let ceiling: Urgency

        /// What every call needs and the declaration can build once: the
        /// label, the policy at each urgency, and the backend's state.
        let cache: OperationCache

        init(backend: Backend, name: String, safety: RepeatSafety, length: Length, ceiling: Urgency) {
            self.backend = backend
            self.name = name
            self.safety = safety
            self.length = length
            self.ceiling = ceiling
            self.cache = OperationCache(backend: backend, name: name, safety: safety, length: length, ceiling: ceiling)
        }

        /// The policy `perform` uses at `urgency`, capped by the ceiling: a
        /// pure function of the declaration, its backend's kind and
        /// capacity, and the urgency, so a test can print it and assert it.
        ///
        ///     #expect(Catalogue.episode.policy(at: .interactive).schedule.maximumAttempts == 2)
        public func policy(at urgency: Urgency) -> OperationPolicy {
            cache.policies[min(urgency, ceiling).rank]
        }

        public static func == (lhs: Operation, rhs: Operation) -> Bool {
            lhs.backend == rhs.backend && lhs.name == rhs.name && lhs.safety == rhs.safety
                && lhs.length == rhs.length && lhs.ceiling == rhs.ceiling
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(backend)
            hasher.combine(name)
            hasher.combine(safety)
            hasher.combine(length)
            hasher.combine(ceiling)
        }

        public var description: String {
            "\(cache.label) (\(safety), \(length))"
        }
    }
}

/// What a declaration builds once for all its calls.
final class OperationCache: Sendable {
    /// `<backend>.<operation>`: the label of every event a call reports.
    let label: String

    /// The policy at each urgency, indexed by ``Urgency/rank``, ceiling
    /// applied.
    let policies: [OperationPolicy]

    /// The backend's state in the process registry, once a call found it.
    let state = AtomicLazyReference<BackendState>()

    init(backend: Backend, name: String, safety: RepeatSafety, length: Backend.Operation.Length, ceiling: Urgency) {
        label = "\(backend.name).\(name)"
        policies = Urgency.allByRank.map { urgency in
            OperationPolicy.derived(kind: backend.kind, capacity: backend.capacity, safety: safety, length: length, urgency: min(urgency, ceiling))
        }
    }
}

extension Urgency {
    /// 0 for ``background`` up to 3 for ``interactive``.
    var rank: Int {
        switch self {
        case .background: 0
        case .utility: 1
        case .userInitiated: 2
        case .interactive: 3
        }
    }

    /// Every urgency, in rank order.
    static let allByRank: [Urgency] = [.background, .utility, .userInitiated, .interactive]
}
