public import Observation
public import Stoic
internal import Synchronization

/// A value that arrives over time, whose phases cannot be mistaken for each
/// other (design/31).
///
/// There is no `value` property, no `isLoading` and no `Bool`: a screen
/// switches on ``phase`` and says what it draws for each case. A value that has
/// not loaded cannot be read as empty, and `.fresh([])` is a list with nothing
/// in it.
///
///     let event = Live(Events.detail) { [api] _ in try await api.event(id) }
///
///     switch event.phase {
///     case .pending: ProgressView()
///     case .failed(let failure, last: nil): FailureView(failure) { event.refresh() }
///     case .fresh(let event), .stale(let event, refreshing: _), .failed(_, last: let event?): EventDetails(event)
///     }
///
/// **Loads are declared operations** (`.readOnly` or `.idempotent`, because a
/// superseded load runs again), run through `perform` in a `TaskSlot`: the
/// latest request wins, and a superseded load's result is never delivered.
/// **Nothing loads until someone looks**: the first read of ``phase`` starts the
/// first load, and a read of a stale value refreshes it; the read itself
/// changes nothing a view observes. A failed value is not refreshed by reading
/// it: ``refresh()``, its own `freshFor` or ``invalidate()`` does.
///
/// Several lives combine only into snapshots whose parts belong together
/// (``combining(_:_:label:_:)``), and two lists join by key, never by position
/// (``joining(_:_:on:_:label:_:)``).
@MainActor
public final class Live<Value: Sendable>: Observable {
    /// Where the live value is.
    public enum Phase {
        /// Nothing has loaded yet; the first load may be running.
        case pending
        /// The latest load returned the value, and nothing has made it old.
        case fresh(Value)
        /// The value is no longer known to be current; `refreshing` says a load is out.
        case stale(Value, refreshing: Bool)
        /// The latest load failed; the value before it, if there was one.
        case failed(Presented, last: Value?)
    }

    /// Names the live value in events.
    public let label: String

    let source: LiveSource<Value>
    private let registrar = ObservationRegistrar()
    // Built once: a key path into a generic class is otherwise rebuilt, and
    // its generic arguments demangled, every time its literal is evaluated.
    private let phaseKeyPath: KeyPath<Live, Phase> = \.phase
    private let clock: AnyClock
    private let wallClock: WallClock

    // What the phase is made of. Mutated only through `change`, so every
    // change is observed.
    private var value: Value?
    private var loaded: Moment?
    private var failure: Presented?
    private var isStale = false
    /// A load is out, as the phase shows it: set from the main actor's turn
    /// after the read that started it.
    private var loading = false

    // Bookkeeping no view observes.
    private var started = false
    private var inFlight = false
    /// An invalidation came while a load was out: what it brings predates
    /// it, so it arrives stale.
    private var invalidatedInFlight = false
    /// Bumped on every value delivered: what a combination's snapshot and the
    /// freshness timer compare.
    private(set) var version = 0
    /// Callers of ``refreshed()`` waiting for the load in flight. Behind a
    /// lock so a caller's cancellation can leave without the main actor.
    private let waiters = Mutex(LoadWaiters())
    private var subscriptionBegan: AnyClock.Instant?
    private var subscriptionEnded = false

    private let loads: TaskSlot<Result<Value, any Error>, Never>
    private let subscription: TaskSlot<Result<Void, any Error>, Never>
    private let freshness: TaskSlot<Bool, Never>

    init(label: String, source: LiveSource<Value>) {
        self.label = label
        self.source = source
        clock = Ambient.current.clock
        wallClock = Ambient.current.wallClock
        loads = TaskSlot(label: "live.\(label).load")
        subscription = TaskSlot(label: "live.\(label).subscription")
        freshness = TaskSlot(label: "live.\(label).freshness")
    }

    /// A value loaded by a declared operation.
    ///
    /// - Parameters:
    ///   - operation: The declared load. Must be `.readOnly` or `.idempotent`:
    ///     a superseded load runs again.
    ///   - freshFor: How long a value stays fresh, on the ambient clock; `nil`,
    ///     the default, keeps it fresh until ``invalidate()`` or ``refresh()``.
    ///   - label: Names it in events; the operation's label by default.
    ///   - load: One attempt, off the main actor.
    public convenience init<Failure: Error>(
        _ operation: Backend.Operation, freshFor: Duration? = nil, label: String? = nil,
        load: @escaping @concurrent @Sendable (Attempt) async throws(Failure) -> Value
    ) {
        precondition(
            operation.safety == .readOnly || operation.safety == .idempotent,
            "Live \(operation): a load must be .readOnly or .idempotent, not \(operation.safety): a superseded load runs again")
        precondition(freshFor.map { $0 > .zero } ?? true, "Live \(operation): freshFor must be positive")
        self.init(label: label ?? Self.name(of: operation), source: .load(LoadSource(operation: operation, freshFor: freshFor, load: load)))
    }

    /// A value kept up to date by a subscription the operation establishes:
    /// each element is a fresh value.
    ///
    /// While the subscription is re-established after a failure the phase is
    /// `.stale(v, refreshing: true)` (or `.pending` before any value); when
    /// establishing it fails, `.failed`. A subscription that ends without
    /// failing leaves `.stale(v, refreshing: false)`, and the next read
    /// subscribes again, no sooner than a second after the last began.
    ///
    /// - Parameters:
    ///   - operation: The declared operation that establishes it. Must be
    ///     `.readOnly` or `.idempotent`.
    ///   - label: Names it in events; the operation's label by default.
    ///   - subscribe: Establishes the subscription, off the main actor.
    public convenience init<Updates: AsyncSequence & Sendable, Failure: Error>(
        subscribing operation: Backend.Operation, label: String? = nil,
        subscribe: @escaping @concurrent @Sendable (Attempt) async throws(Failure) -> Updates
    ) where Updates.Element == Value {
        precondition(
            operation.safety == .readOnly || operation.safety == .idempotent,
            "Live \(operation): a subscription must be .readOnly or .idempotent, not \(operation.safety)")
        self.init(
            label: label ?? Self.name(of: operation),
            source: .subscribe(SubscribeSource(operation: operation, subscribe: subscribe)))
    }

    private static func name(of operation: Backend.Operation) -> String {
        "\(operation.backend.name).\(operation.name)"
    }

    // MARK: Reading

    /// The phase: observable, and the first read starts the first load.
    public var phase: Phase {
        registrar.access(self, keyPath: phaseKeyPath)
        if case .combination(let combination) = source { return combination.phase(for: self) }
        startIfNeeded()
        return current
    }

    /// When the phase's value was loaded; `nil` exactly when it holds none.
    /// For "updated 3 minutes ago", never for deciding.
    public var loadedAt: Moment? {
        registrar.access(self, keyPath: phaseKeyPath)
        if case .combination(let combination) = source { return combination.loadedAt(for: self) }
        return value == nil ? nil : loaded
    }

    /// The phase from what is held, without starting anything; observed, as
    /// ``phase`` is.
    var current: Phase {
        registrar.access(self, keyPath: phaseKeyPath)
        if let failure { return .failed(failure, last: value) }
        guard let value else { return .pending }
        return isStale || loading ? .stale(value, refreshing: loading) : .fresh(value)
    }

    /// What a combination needs of an input: its phase (read, so it loads and
    /// is observed), its version and when its value was loaded.
    var asInput: CombinationInput {
        let phase = self.phase
        let kind: CombinationInput.Kind = switch phase {
        case .pending: .pending
        case .failed(let presented, _): .failed(presented)
        case .stale(_, refreshing: true): .refreshing
        case .stale(_, refreshing: false): .stale
        case .fresh: .fresh
        }
        return CombinationInput(kind: kind, version: combinationVersion, loadedAt: loadedAt)
    }

    /// A combination's own value: the value the input holds now, if any.
    var heldValue: Value? {
        switch phase {
        case .pending: nil
        case .fresh(let value), .stale(let value, _): value
        case .failed(_, let last): last
        }
    }

    private var combinationVersion: Int {
        if case .combination(let combination) = source { return combination.version }
        return version
    }

    // MARK: Loading

    /// Loads now; a load in flight is superseded, and its result is never
    /// delivered. At `.interactive` while nothing has loaded (a person is
    /// looking at a spinner), else at `.utility`. On a combination, every
    /// input at once: a consistent new snapshot.
    public func refresh() {
        refresh(urgency: nil)
    }

    /// ``refresh()``, waiting for its outcome, at `.interactive` (a pull to
    /// refresh). Returns the phase as it is when the caller is cancelled; the
    /// load goes on.
    @discardableResult
    public func refreshed() async -> Phase {
        refresh(urgency: .interactive)
        await waitForLoad()
        return phase
    }

    /// `urgency`, or the one who is waiting implies.
    func refresh(urgency: Urgency?) {
        if case .combination(let combination) = source { return combination.refreshAll(urgency: urgency) }
        change {
            if value != nil { isStale = true }
            failure = nil
        }
        start(urgency: urgency ?? (value == nil ? .interactive : .utility))
    }

    /// The value is stale now: the next read refreshes it. A failed value
    /// loads again at the next read too.
    public func invalidate() {
        if case .combination(let combination) = source { return combination.invalidateAll() }
        if inFlight { invalidatedInFlight = true }
        guard value != nil || failure != nil else { return }
        change {
            if value != nil { isStale = true }
            if failure != nil {
                failure = nil
                // Nothing held and nothing out: the next read starts again.
                if value == nil { started = false }
            }
        }
    }

    private func startIfNeeded() {
        guard !inFlight else { return }
        if !started {
            started = true
            start(urgency: .interactive)
            return
        }
        guard failure == nil, value != nil else { return }
        if case .subscribe = source, subscriptionEnded {
            start(urgency: .utility)
        } else if isStale {
            start(urgency: .utility)
        }
    }

    private func start(urgency: Urgency) {
        started = true
        inFlight = true
        // This load starts after any invalidation so far.
        invalidatedInFlight = false
        switch source {
        case .load(let load):
            loads.run(for: self) { [weak self] () async -> Result<Value, any Error> in
                self?.markLoading()
                return await load.run(urgency)
            } deliver: { @MainActor live, result in
                switch result {
                case .success(let outcome): live.delivered(outcome)
                }
            }
        case .subscribe(let subscribing):
            let notBefore = subscriptionBegan.map { $0.advanced(by: .seconds(1)) }
            subscriptionEnded = false
            subscription.run(for: self) { [weak self, clock] () async -> Result<Void, any Error> in
                self?.markLoading()
                return await subscribing.run(
                    urgency: urgency, clock: clock, notBefore: notBefore,
                    began: { @MainActor [weak self] instant in self?.subscriptionBegan = instant },
                    receive: { @MainActor [weak self] value in self?.received(value) },
                    reconnecting: { @MainActor [weak self] in self?.markLoading() })
            } deliver: { @MainActor live, result in
                switch result {
                case .success(let outcome): live.subscriptionStopped(outcome)
                }
            }
        case .combination:
            break
        }
    }

    private func markLoading() {
        guard !loading else { return }
        change { loading = true }
    }

    private func delivered(_ result: Result<Value, any Error>) {
        inFlight = false
        switch result {
        case .success(let value):
            received(value)
        case .failure(let error):
            fail(error)
        }
        resumeWaiters()
    }

    private func received(_ value: Value) {
        change {
            self.value = value
            loaded = wallClock.now
            failure = nil
            isStale = invalidatedInFlight
            // A value is what a load, or a subscription that is live, ends
            // waiting with.
            loading = false
            version += 1
        }
        invalidatedInFlight = false
        armFreshness()
    }

    private func fail(_ error: any Error) {
        // A load that ends in cancellation changes nothing.
        guard let presented = error.presented() else {
            change { loading = false }
            return
        }
        Ambient.record(Event("live.failed", level: .notice, label: label, fields: [
            .init("reference", .string(presented.reference.description), privacy: .public),
            .init("key", .string(presented.message.key), privacy: .public),
        ]))
        change {
            failure = presented
            loading = false
        }
    }

    private func subscriptionStopped(_ result: Result<Void, any Error>) {
        inFlight = false
        subscriptionEnded = true
        switch result {
        case .success:
            change {
                loading = false
                if value != nil { isStale = true }
            }
        case .failure(let error):
            fail(error)
        }
        resumeWaiters()
    }

    /// Goes stale `freshFor` after the value now held was loaded, on the
    /// clock: the instant is fixed now.
    private func armFreshness() {
        guard case .load(let load) = source, let freshFor = load.freshFor else { return }
        let until = clock.now.advanced(by: freshFor)
        let armed = version
        freshness.run(for: self) { [clock] () async -> Bool in
            do {
                try await clock.sleep(until: until, tolerance: nil)
                return true
            } catch {
                return false
            }
        } deliver: { @MainActor live, result in
            guard case .success(true) = result, live.version == armed else { return }
            live.change {
                if live.value != nil { live.isStale = true }
                live.failure = nil
            }
        }
    }

    /// Returns when the load in flight ends (at once if none is), or when the
    /// caller is cancelled.
    func waitForLoad() async {
        if case .combination(let combination) = source { return await combination.loadedAll() }
        guard inFlight else { return }
        let id = waiters.withLock { $0.next() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if !waiters.withLock({ $0.park(id, continuation) }) { continuation.resume() }
            }
        } onCancel: {
            waiters.withLock { $0.cancel(id) }?.resume()
        }
    }

    private func resumeWaiters() {
        for waiter in waiters.withLock({ $0.takeAll() }) { waiter.resume() }
    }

    /// Applies `mutation` as one observed change of the phase.
    func change(_ mutation: () -> Void) {
        registrar.withMutation(of: self, keyPath: phaseKeyPath, mutation)
    }

    // MARK: Permissions

    /// A live permission check as the check itself (design/28): loading is
    /// `.unknown(.loading)`, and a failed refresh is `.unknown(.unavailable)`,
    /// even if a grant was held, since unknown is not an answer. A stale check
    /// is the check: a client's grant is advisory, and the server checks again.
    public func check<P: Permission>() -> PermissionCheck<P> where Value == PermissionCheck<P> {
        switch phase {
        case .pending: .unknown(.loading)
        case .fresh(let check), .stale(let check, _): check
        case .failed(let presented, _): .unknown(.unavailable("reference \(presented.reference)"))
        }
    }

    /// ``check()``, but a grant held when a refresh failed keeps granting for
    /// `duration` after it was loaded: a declared choice for a screen that may
    /// keep drawing an edit button through a brief outage, since the server
    /// checks again. A denial, or a grant older than that, is unknown.
    public func check<P: Permission>(keepingGrantFor duration: Duration) -> PermissionCheck<P> where Value == PermissionCheck<P> {
        switch phase {
        case .failed(_, last: .granted(let grant)?):
            if let loaded = loadedAt, wallClock.now < loaded + duration { return .granted(grant) }
            return check()
        default:
            return check()
        }
    }
}

extension Live: Refreshable {}

/// The callers of ``Live/refreshed()`` waiting for a load, by arrival.
struct LoadWaiters {
    private var counter = 0
    private var parked: [Int: CheckedContinuation<Void, Never>] = [:]
    private var cancelled: Set<Int> = []

    mutating func next() -> Int {
        defer { counter += 1 }
        return counter
    }

    /// Parks `id`'s continuation; false when it was cancelled first.
    mutating func park(_ id: Int, _ continuation: CheckedContinuation<Void, Never>) -> Bool {
        guard cancelled.remove(id) == nil else { return false }
        parked[id] = continuation
        return true
    }

    mutating func cancel(_ id: Int) -> CheckedContinuation<Void, Never>? {
        if let continuation = parked.removeValue(forKey: id) { return continuation }
        cancelled.insert(id)
        return nil
    }

    mutating func takeAll() -> [CheckedContinuation<Void, Never>] {
        defer { parked = [:] }
        return parked.sorted { $0.key < $1.key }.map(\.value)
    }
}

/// Something an action's success makes stale: a ``Live``, or anything that
/// can be invalidated together with others in one main-actor turn.
@MainActor
public protocol Refreshable: AnyObject {
    func invalidate()
}

extension Live.Phase: Sendable {}

extension Live.Phase: Equatable where Value: Equatable {}

extension Live.Phase {
    /// The phase with its value, if any, transformed.
    public func map<U>(_ transform: (Value) -> U) -> Live<U>.Phase {
        switch self {
        case .pending: .pending
        case .fresh(let value): .fresh(transform(value))
        case .stale(let value, let refreshing): .stale(transform(value), refreshing: refreshing)
        case .failed(let presented, let last): .failed(presented, last: last.map(transform))
        }
    }
}

// MARK: Combinations

extension Live {
    /// One snapshot of two lives, computed only from values that belong
    /// together (design/31, Live: combinations).
    ///
    /// Its phase follows its inputs, the first rule that applies winning: any
    /// input failed is `.failed(its presentation, last: the last snapshot)`;
    /// any pending is `.pending`; any refreshing keeps the last snapshot as
    /// `.stale(_, refreshing: true)`, **not recomputed**, so a screen never shows
    /// a new input beside an old one; any stale recomputes, `.stale`; all fresh
    /// recomputes, `.fresh`. Reading it reads its inputs, so it starts their
    /// loads; `refresh()` and `invalidate()` act on every input at once.
    public static func combining<A, B>(
        _ a: Live<A>, _ b: Live<B>, label: String? = nil, _ combine: @escaping @Sendable (A, B) -> Value
    ) -> Live<Value> {
        Live(label: label ?? "\(a.label)+\(b.label)", source: .combination(Combination([.init(a), .init(b)]) {
            guard let a = a.heldValue, let b = b.heldValue else { return nil }
            return combine(a, b)
        }))
    }

    /// One snapshot of three lives; see ``combining(_:_:label:_:)``.
    public static func combining<A, B, C>(
        _ a: Live<A>, _ b: Live<B>, _ c: Live<C>, label: String? = nil, _ combine: @escaping @Sendable (A, B, C) -> Value
    ) -> Live<Value> {
        Live(label: label ?? "\(a.label)+\(b.label)+\(c.label)", source: .combination(Combination([.init(a), .init(b), .init(c)]) {
            guard let a = a.heldValue, let b = b.heldValue, let c = c.heldValue else { return nil }
            return combine(a, b, c)
        }))
    }

    /// One snapshot of four lives; see ``combining(_:_:label:_:)``.
    public static func combining<A, B, C, D>(
        _ a: Live<A>, _ b: Live<B>, _ c: Live<C>, _ d: Live<D>, label: String? = nil,
        _ combine: @escaping @Sendable (A, B, C, D) -> Value
    ) -> Live<Value> {
        Live(
            label: label ?? "\(a.label)+\(b.label)+\(c.label)+\(d.label)",
            source: .combination(Combination([.init(a), .init(b), .init(c), .init(d)]) {
                guard let a = a.heldValue, let b = b.heldValue, let c = c.heldValue, let d = d.heldValue else { return nil }
                return combine(a, b, c, d)
            }))
    }

    /// Two lists joined by key, in the left list's order: never by position.
    ///
    /// Each element of `left` is paired with the element of `right` that has
    /// the same key; one with no partner gets `nil`, which inside a
    /// combination means "not in the answer", never "not loaded yet" (the
    /// combination has no value until both lists have loaded). A key repeated
    /// on the right is a defect in the data: the first wins, and
    /// `live.join_duplicate_key` reports how many at error level. Keys repeated
    /// on the left each join.
    public static func joining<A, B, K: Hashable & Sendable, Row: Sendable>(
        _ left: Live<[A]>, _ right: Live<[B]>,
        on leftKey: any KeyPath<A, K> & Sendable, _ rightKey: any KeyPath<B, K> & Sendable, label: String? = nil,
        _ row: @escaping @Sendable (A, B?) -> Row
    ) -> Live<[Row]> where Value == [Row] {
        let name = label ?? "\(left.label)⋈\(right.label)"
        return combining(left, right, label: name) { lefts, rights in
            var byKey: [K: B] = [:]
            var repeated = 0
            for element in rights {
                let key = element[keyPath: rightKey]
                if byKey[key] == nil { byKey[key] = element } else { repeated += 1 }
            }
            if repeated > 0 {
                Ambient.record(Event("live.join_duplicate_key", level: .error, label: name, fields: [
                    .init("repeated", .int(repeated)),
                ]))
            }
            return lefts.map { row($0, byKey[$0[keyPath: leftKey]]) }
        }
    }
}
