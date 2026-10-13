/// A cache whose entries go stale, and are refreshed in the background
/// while the stale value is still served.
///
/// The screen that shows a user's profile wants it now, even if it is a
/// minute old, and wants a fresh copy by the time it is looked at again. An
/// entry has three ages:
///
/// - **Fresh** (younger than `ttl`): returned as it is.
/// - **Stale** (older than `ttl`, younger than `ttl + staleWindow`): returned
///   as it is, and a refresh is started in the background, once per key.
/// - **Expired**: forgotten. The caller waits for a load.
///
/// Loads go through a ``SingleFlight``, so any number of callers asking for a
/// key that is loading share one run of the loader, and so does a refresh
/// that a cold caller arrives in the middle of. The load belongs to the
/// flight, not to a caller: a caller that is cancelled (or whose deadline
/// passes) leaves with a rejection, and the load goes on for the others.
///
/// **Refreshes belong to a scope.** The cache forks them into the
/// ``TaskScope`` it is created with, so ending the scope cancels and awaits
/// them, and they cannot outlive what the loader uses. A cache must not
/// outlive its scope: after it, stale entries are still served but no longer
/// refreshed, and expire as usual.
///
/// **Failures.** A refresh that fails keeps the stale value, which goes on
/// being served (and refreshed again by the next stale read, until the window
/// closes), and is reported as `cache.refresh_failed`. A load that fails with
/// nobody to fall back on is thrown to every waiting caller as `.failed` and,
/// by default, forgotten, so the next caller tries again. With
/// `negativeTTL`, that failure is remembered for that long and thrown to
/// callers without calling the loader. Cancelled loads and rejections are never
/// remembered.
///
/// **Bounded.** At most `maxEntries` entries are kept; adding one over the
/// limit evicts the least recently used. Failures are entries too.
///
/// Time is measured on the clock the cache is created with.
public actor ExpiringCache<Key: Hashable & Sendable, Value: Sendable, Failure: Error> {
    public nonisolated let label: String
    public nonisolated let ttl: Duration
    public nonisolated let staleWindow: Duration
    public nonisolated let maxEntries: Int
    public nonisolated let negativeTTL: Duration?

    private struct Entry {
        var result: Result<Value, Failure>
        let storedAt: AnyClock.Instant
        var touched: UInt64
    }

    private let clock: AnyClock
    private let loader: @Sendable (Key) async throws(Failure) -> Value
    private let flight: SingleFlight<Key, Value, Failure>
    private let tasks: TaskScopeState
    private var entries: [Key: Entry] = [:]
    // Least recently used first. A key is appended on every use and an old
    // tuple is skipped when its `touched` no longer matches the entry's, so
    // a use costs O(1); the queue is rebuilt from the entries when it grows
    // past a few times their limit.
    private var recency: [(key: Key, touched: UInt64)] = []
    private var recencyHead = 0
    private var tick: UInt64 = 0
    private var refreshing: Set<Key> = []

    /// Creates a cache whose background refreshes belong to `scope`.
    ///
    /// - Parameters:
    ///   - scope: Owns the background refreshes; unused when `staleWindow` is zero.
    ///   - ttl: How long an entry is fresh. Positive.
    ///   - staleWindow: How much longer it may be served while it refreshes.
    ///   - maxEntries: The most entries kept, least recently used evicted. At least 1.
    ///   - negativeTTL: How long a failed load is remembered; `nil` (the
    ///     default) remembers none.
    ///   - label: Names the cache in events and rejections.
    ///   - clock: The clock to measure on; by default the ambient clock when
    ///     the cache is created.
    ///   - loader: Loads a value. Runs without any caller's deadline.
    public static func make(
        in scope: borrowing TaskScope,
        ttl: Duration,
        staleWindow: Duration = .zero,
        maxEntries: Int,
        negativeTTL: Duration? = nil,
        label: String,
        clock: AnyClock? = nil,
        loader: @escaping @Sendable (Key) async throws(Failure) -> Value
    ) -> ExpiringCache {
        ExpiringCache(ttl: ttl, staleWindow: staleWindow, maxEntries: maxEntries, negativeTTL: negativeTTL,
                      label: label, clock: clock, tasks: scope.tasks, loader: loader)
    }

    // A factory rather than an initializer: a scope is not `Sendable`, so an
    // actor's initializer, which runs in the actor's region, cannot take one.
    private init(
        ttl: Duration, staleWindow: Duration, maxEntries: Int, negativeTTL: Duration?, label: String,
        clock: AnyClock?, tasks: TaskScopeState, loader: @escaping @Sendable (Key) async throws(Failure) -> Value
    ) {
        precondition(ttl > .zero, "an entry must be fresh for some time")
        precondition(staleWindow >= .zero, "a stale window cannot be negative")
        precondition(maxEntries >= 1, "a cache must hold at least one entry")
        precondition(negativeTTL.map { $0 > .zero } ?? true, "a negative TTL must be positive, or nil for none")
        self.label = label
        self.ttl = ttl
        self.staleWindow = staleWindow
        self.maxEntries = maxEntries
        self.negativeTTL = negativeTTL
        self.clock = clock ?? Ambient.current.clock
        self.loader = loader
        self.tasks = tasks
        flight = SingleFlight(label: label)
    }

    /// The entries held right now, expired ones not yet noticed included.
    public var count: Int { entries.count }

    /// The keys being refreshed in the background; for tests.
    var refreshCount: Int { refreshing.count }

    /// The callers waiting on `key`'s load; for tests.
    nonisolated func waiterCount(for key: Key) -> Int {
        flight.waiterCount(for: key)
    }

    /// The value for `key`: cached if fresh or stale, else loaded.
    ///
    /// - Throws: `.failed` with the loader's error (a cold load's, or a
    ///   remembered one), or `.rejected` when this caller stopped waiting:
    ///   `.cancelled` or `.deadlineExceeded`.
    public func value(for key: Key) async throws(PolicyError<Failure>) -> Value {
        if let refusal = Rejection.refusedBeforeStart(label: label) { throw .rejected(refusal) }
        if let entry = entries[key] {
            let age = entry.storedAt.duration(to: clock.now)
            switch entry.result {
            case .success(let value) where age < ttl:
                use(key)
                return value
            case .success(let value) where age < ttl.saturatingAdding(staleWindow):
                use(key)
                startRefresh(key)
                return value
            case .failure(let error) where age < (negativeTTL ?? .zero):
                use(key)
                throw .failed(error)
            default:
                entries[key] = nil
            }
        }
        return try await flight.run(key, operation: load(key))
    }

    // The flight's operation: whoever started the flight, the first outcome
    // is stored once, here, rather than by each waiter.
    private func load(_ key: Key) -> @concurrent @Sendable () async throws(Failure) -> Value {
        { [self, loader] () async throws(Failure) -> Value in
            do throws(Failure) {
                let value = try await loader(key)
                await store(key, .success(value))
                return value
            } catch {
                await store(key, .failure(error))
                throw error
            }
        }
    }

    private func store(_ key: Key, _ result: Result<Value, Failure>) {
        if case .failure = result {
            // A load nobody waits for any more says nothing about the key; a
            // failed refresh keeps the value it was refreshing.
            guard negativeTTL != nil, !Task.isCancelled else { return }
            if case .success? = entries[key]?.result, entries[key]!.storedAt.duration(to: clock.now) < ttl.saturatingAdding(staleWindow) { return }
        }
        entries[key] = Entry(result: result, storedAt: clock.now, touched: 0)
        use(key)
        while entries.count > maxEntries, recencyHead < recency.count {
            let oldest = recency[recencyHead]
            recencyHead += 1
            if entries[oldest.key]?.touched == oldest.touched { entries[oldest.key] = nil }
        }
    }

    private func use(_ key: Key) {
        tick += 1
        entries[key]?.touched = tick
        recency.append((key, tick))
        if recencyHead > 64, recencyHead * 2 > recency.count {
            recency.removeFirst(recencyHead)
            recencyHead = 0
        }
        if recency.count - recencyHead > 4 * maxEntries + 16 {
            recency = entries.map { ($0.key, $0.value.touched) }.sorted { $0.1 < $1.1 }.map { (key: $0.0, touched: $0.1) }
            recencyHead = 0
        }
    }

    private func startRefresh(_ key: Key) {
        guard refreshing.insert(key).inserted else { return }
        tasks.fork(label: "\(label).refresh") { [self] in await refresh(key) }
    }

    private func refresh(_ key: Key) async {
        defer { refreshing.remove(key) }
        do throws(PolicyError<Failure>) {
            _ = try await flight.run(key, operation: load(key))
        } catch {
            // A rejection is the scope ending the refresh: not a failure.
            guard case .failed(let failure) = error else { return }
            Ambient.record(Event("cache.refresh_failed", level: .warning, label: label, fields: [.init("error", .error(failure))]))
        }
    }
}
