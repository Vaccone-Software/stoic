public import Stoic

/// Where a live value comes from.
enum LiveSource<Value: Sendable>: Sendable {
    case load(LoadSource<Value>)
    case subscribe(SubscribeSource<Value>)
    case combination(Combination<Value>)
}

/// A load through a declared operation, at an urgency.
struct LoadSource<Value: Sendable>: Sendable {
    let freshFor: Duration?
    let run: @concurrent @Sendable (Urgency) async -> Result<Value, any Error>

    init<Failure: Error>(
        operation: Backend.Operation, freshFor: Duration?,
        load: @escaping @concurrent @Sendable (Attempt) async throws(Failure) -> Value
    ) {
        self.freshFor = freshFor
        run = { @concurrent urgency in
            await withUrgency(urgency) { () async -> Result<Value, any Error> in
                do throws(OperationError<Failure>) {
                    return .success(try await operation.perform { attempt throws(Failure) in try await load(attempt) })
                } catch {
                    return .failure(error)
                }
            }
        }
    }
}

/// A subscription a declared operation establishes, iterated until it ends,
/// re-established after it fails.
struct SubscribeSource<Value: Sendable>: Sendable {
    typealias Run = @concurrent @Sendable (
        _ urgency: Urgency, _ clock: AnyClock, _ notBefore: AnyClock.Instant?,
        _ began: @escaping @MainActor @Sendable (AnyClock.Instant) -> Void,
        _ receive: @escaping @MainActor @Sendable (Value) -> Void,
        _ reconnecting: @escaping @MainActor @Sendable () -> Void
    ) async -> Result<Void, any Error>

    private let body: Run

    init<Updates: AsyncSequence & Sendable, Failure: Error>(
        operation: Backend.Operation,
        subscribe: @escaping @concurrent @Sendable (Attempt) async throws(Failure) -> Updates
    ) where Updates.Element == Value {
        body = { @concurrent urgency, clock, notBefore, began, receive, reconnecting in
            /// Sleeps until `instant`; false when cancelled meanwhile.
            func wait(until instant: AnyClock.Instant) async -> Bool {
                guard clock.now < instant else { return true }
                do {
                    try await clock.sleep(until: instant, tolerance: nil)
                    return true
                } catch {
                    return false
                }
            }
            // A subscription that ended at once cannot make reads spin.
            if let notBefore, !(await wait(until: notBefore)) { return .success(()) }
            while !Task.isCancelled {
                let started = clock.now
                await began(started)
                let updates: Updates
                do throws(OperationError<Failure>) {
                    updates = try await withUrgency(urgency) { () async throws(OperationError<Failure>) -> Updates in
                        try await operation.perform { attempt throws(Failure) in try await subscribe(attempt) }
                    }
                } catch {
                    return .failure(error)
                }
                do {
                    for try await element in updates {
                        if Task.isCancelled { return .success(()) }
                        await receive(element)
                    }
                    // Ended without failing: the next read subscribes again.
                    return .success(())
                } catch {
                    if Task.isCancelled { return .success(()) }
                    // Failed while running: re-established, no sooner than a
                    // second after this one began.
                    await reconnecting()
                    if !(await wait(until: started.advanced(by: .seconds(1)))) { return .success(()) }
                }
            }
            return .success(())
        }
    }

    func run(
        urgency: Urgency, clock: AnyClock, notBefore: AnyClock.Instant?,
        began: @escaping @MainActor @Sendable (AnyClock.Instant) -> Void,
        receive: @escaping @MainActor @Sendable (Value) -> Void,
        reconnecting: @escaping @MainActor @Sendable () -> Void
    ) async -> Result<Void, any Error> {
        await body(urgency, clock, notBefore, began, receive, reconnecting)
    }
}

/// What a combination reads of one input.
struct CombinationInput: Sendable {
    enum Kind: Sendable {
        case pending, failed(Presented), refreshing, stale, fresh
    }

    let kind: Kind
    /// Changes whenever the input's value does.
    let version: Int
    let loadedAt: Moment?
}

/// One snapshot of several lives, computed only from values that belong
/// together (design/31, Live: combinations).
@MainActor
final class Combination<Value: Sendable>: Sendable {
    struct Input {
        let read: @MainActor () -> CombinationInput
        let refresh: @MainActor (Urgency?) -> Void
        let invalidate: @MainActor () -> Void
        let loaded: @MainActor () async -> Void

        init<A>(_ live: Live<A>) {
            read = { live.asInput }
            refresh = { live.refresh(urgency: $0) }
            invalidate = { live.invalidate() }
            loaded = { await live.waitForLoad() }
        }
    }

    private let inputs: [Input]
    private let compute: @MainActor () -> Value?
    private var snapshot: (versions: [Int], value: Value, loadedAt: Moment?)?
    /// Bumped whenever a new snapshot is made: what a combination of
    /// combinations compares.
    private(set) var version = 0

    init(_ inputs: [Input], compute: @escaping @MainActor () -> Value?) {
        self.inputs = inputs
        self.compute = compute
    }

    /// The first rule that applies wins: any input failed; any pending; any
    /// refreshing (the last snapshot, not recomputed); any stale; all fresh.
    func phase(for live: Live<Value>) -> Live<Value>.Phase {
        let states = inputs.map { $0.read() }
        for state in states {
            if case .failed(let presented) = state.kind { return .failed(presented, last: snapshot?.value) }
        }
        if states.contains(where: { if case .pending = $0.kind { true } else { false } }) { return .pending }
        let versions = states.map(\.version)
        if states.contains(where: { if case .refreshing = $0.kind { true } else { false } }) {
            // Mid-refresh: never a new input beside an old one. With no
            // snapshot yet, one is made from the inputs' current values.
            if snapshot == nil { make(versions, states) }
            return snapshot.map { .stale($0.value, refreshing: true) } ?? .pending
        }
        if snapshot?.versions != versions { make(versions, states) }
        guard let snapshot else { return .pending }
        let stale = states.contains { if case .stale = $0.kind { true } else { false } }
        return stale ? .stale(snapshot.value, refreshing: false) : .fresh(snapshot.value)
    }

    /// The snapshot's moment: its oldest part's.
    func loadedAt(for live: Live<Value>) -> Moment? {
        switch phase(for: live) {
        case .pending, .failed(_, last: nil): nil
        default: snapshot?.loadedAt
        }
    }

    private func make(_ versions: [Int], _ states: [CombinationInput]) {
        guard let value = compute() else { return }
        snapshot = (versions, value, states.compactMap(\.loadedAt).min())
        version += 1
    }

    func refreshAll(urgency: Urgency?) {
        for input in inputs { input.refresh(urgency) }
    }

    func invalidateAll() {
        for input in inputs { input.invalidate() }
    }

    /// Waits until every input's load in flight has ended.
    func loadedAll() async {
        for input in inputs { await input.loaded() }
    }
}
