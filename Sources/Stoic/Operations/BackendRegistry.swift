internal import Synchronization

/// The state of every declared backend: its breaker, its bulkhead with
/// urgency partitions and writer lane, and its retry budget.
///
/// A ``Backend`` is a value; this is where what it remembers lives, created
/// on first use and keyed by name. One lives in ``Ambient/backends``: the
/// process shares ``shared``, and `withTestAmbient` gives each test a fresh
/// one, so a test can neither see nor drain another's breaker, and work a
/// test left running keeps that test's registry.
///
/// The registry holds at most 256 backends, forgetting the least recently
/// used one with nothing in flight; when every one has work in flight it
/// grows rather than forget, and reports `operation.registry_full` once.
///
///     try await withAmbient({ $0.backends = BackendRegistry() }) {
///         try await syncEverything()   // breakers and budgets start fresh
///     }
public final class BackendRegistry: Sendable {
    /// The process-wide registry.
    public static let shared = BackendRegistry()

    static let limit = 256

    private static let ids = Atomic<UInt64>(0)

    /// Tells this registry's states from another's, in a declaration's
    /// cache, without keeping the registry alive.
    let id: UInt64

    private struct State {
        var states: [String: BackendState] = [:]
        var reportedFull = false
    }

    private let state = Mutex(State())

    /// A fresh registry: every backend's state starts new in it.
    public init() {
        id = Self.ids.wrappingAdd(1, ordering: .relaxed).newValue
    }

    /// The backends with state right now.
    var count: Int {
        state.withLock { $0.states.count }
    }

    /// The state of `backend`, created with `ambient`'s clock and budgets on
    /// first use, and entered (``BackendState/enter()``): the caller leaves
    /// it when its call ends.
    func enter(_ backend: Backend, ambient: Ambient) -> BackendState {
        let (entered, evicted, full) = state.withLock { state -> (BackendState, BackendState?, Int?) in
            if let existing = state.states[backend.name] {
                existing.enterUnderRegistryLock()
                return (existing, nil, nil)
            }
            var evicted: BackendState?
            var full: Int?
            if state.states.count >= Self.limit {
                // The least recently used state with nothing in flight.
                let idle = state.states.values.filter { $0.tryEvict() }
                if let oldest = idle.min(by: { $0.lastUse < $1.lastUse }) {
                    state.states[oldest.backend.name] = nil
                    evicted = oldest
                    for other in idle where other !== oldest { other.cancelEviction() }
                } else if !state.reportedFull {
                    state.reportedFull = true
                    full = state.states.count + 1
                }
            }
            let created = BackendState(backend: backend, registry: id, ambient: ambient)
            created.enterUnderRegistryLock()
            state.states[backend.name] = created
            return (created, evicted, full)
        }
        evicted?.retire()
        if let full {
            ambient.instrumentation.record(Event("operation.registry_full", level: .warning, label: backend.name, fields: [
                .init("backends", .int(full)),
            ]))
        }
        return entered
    }

    /// The state of `backend` if it has one, without entering it.
    func existing(_ backend: Backend) -> BackendState? {
        state.withLock { $0.states[backend.name] }
    }
}

/// What one backend remembers, in one registry.
final class BackendState: Sendable {
    let backend: Backend
    /// The registry it belongs to.
    let registry: UInt64
    /// Its breaker: `remote` and `system` backends only.
    let breaker: CircuitBreaker?
    /// Its bulkhead, partitioned by urgency.
    let slots: AdmissionGate
    /// Its writer lane: `local` backends only.
    let lane: AdmissionGate?
    /// Its retry budget, registered in the ambient budgets as
    /// `.named(backend.name)`.
    let budget: BudgetStorage
    /// The budgets registry the budget is held in.
    private let budgets: RetryBudgets

    private let calls = Atomic<Int>(0)
    private let used = Atomic<UInt64>(0)
    private let evicted = Atomic<Bool>(false)

    /// Orders uses across every state, for least-recently-used eviction.
    private static let clock = Atomic<UInt64>(0)

    init(backend: Backend, registry: UInt64, ambient: Ambient) {
        self.backend = backend
        self.registry = registry
        let capacity = backend.capacity
        let caps = Urgency.allByRank.map { OperationPolicy.admission(capacity: capacity, urgency: $0) }
        slots = AdmissionGate(label: backend.name, capacity: capacity, caps: caps, waiterLimit: 4 * capacity)
        lane = backend.kind == .local
            ? AdmissionGate(label: backend.name, capacity: 1, caps: [1, 1, 1, 1], waiterLimit: 4 * capacity)
            : nil
        if let policy = OperationPolicy.derived(
            kind: backend.kind, capacity: capacity, safety: .readOnly, length: .brief, urgency: .interactive
        ).breaker {
            // What counts follows classification, and `perform` judges each
            // attempt itself; there is no slow-call rule.
            let configuration = CircuitBreaker.Configuration(minimumCalls: policy.minimumCalls, openDuration: policy.openDuration)
            breaker = CircuitBreaker(
                label: backend.name, configuration: configuration, clock: ambient.clock, judgesSlowCalls: false,
                fileID: #fileID, line: #line
            )
        } else {
            breaker = nil
        }
        budgets = ambient.budgets
        budget = ambient.budgets.hold(name: backend.name)
        used.store(Self.clock.wrappingAdd(1, ordering: .relaxed).newValue, ordering: .relaxed)
    }

    /// When it was last entered, in the order of every state's uses.
    var lastUse: UInt64 {
        used.load(ordering: .relaxed)
    }

    /// Whether the registry has forgotten it.
    var isEvicted: Bool {
        evicted.load(ordering: .sequentiallyConsistent)
    }

    /// Counts a call in, outside the registry's lock (a declaration's cached
    /// state). `false` when the state was forgotten meanwhile: the call goes
    /// to the registry instead.
    ///
    /// The count and the eviction flag are read in the opposite order to
    /// ``tryEvict()``, sequentially consistent, so of a call entering and
    /// an eviction at once, at least one sees the other.
    func enter() -> Bool {
        calls.wrappingAdd(1, ordering: .sequentiallyConsistent)
        if evicted.load(ordering: .sequentiallyConsistent) {
            leave()
            return false
        }
        used.store(Self.clock.wrappingAdd(1, ordering: .relaxed).newValue, ordering: .relaxed)
        return true
    }

    /// Counts a call in under the registry's lock, where nothing evicts.
    fileprivate func enterUnderRegistryLock() {
        calls.wrappingAdd(1, ordering: .sequentiallyConsistent)
        used.store(Self.clock.wrappingAdd(1, ordering: .relaxed).newValue, ordering: .relaxed)
    }

    /// Counts a call out.
    func leave() {
        calls.wrappingSubtract(1, ordering: .sequentiallyConsistent)
    }

    /// Marks it forgotten if nothing is in flight; under the registry's lock.
    fileprivate func tryEvict() -> Bool {
        evicted.store(true, ordering: .sequentiallyConsistent)
        if calls.load(ordering: .sequentiallyConsistent) == 0, slots.isIdle, lane?.isIdle ?? true { return true }
        evicted.store(false, ordering: .sequentiallyConsistent)
        return false
    }

    /// Undoes ``tryEvict()`` for a state that was not chosen.
    fileprivate func cancelEviction() {
        evicted.store(false, ordering: .sequentiallyConsistent)
    }

    /// Lets the budgets registry forget the budget, once evicted.
    fileprivate func retire() {
        budgets.release(name: backend.name)
    }
}
