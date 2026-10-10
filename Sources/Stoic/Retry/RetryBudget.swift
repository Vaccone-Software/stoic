internal import Synchronization

/// A cap on how much retrying may add to the load on a dependency.
///
/// Retries are how a brief outage becomes a long one: five layers each
/// retrying three times multiply the load on a failing database 243-fold
/// (AWS Builders' Library). A budget bounds the extra load no matter how many
/// callers retry. It holds two kinds of token:
///
/// - **Earned** tokens: each first attempt deposits `ratio` of a token. Under
///   a full outage, retries add at most `ratio` of the traffic that is
///   already arriving.
/// - **Reserve** tokens: refilled at `reservePerSecond`, up to
///   `reserveCapacity`, so a quiet app — one user action, not a thousand
///   requests a second — can still retry.
///
/// Each retry spends one token, earned first. With none left, the retry is
/// refused and the last error is rethrown.
///
/// Budgets are shared by everything that retries against one dependency:
/// give them a name with ``named(_:)``, or let ``retry(_:budget:classify:nesting:label:fileID:line:operation:)``
/// use the default, which is one budget per call site.
public struct RetryBudget: Sendable, CustomStringConvertible {
    enum Kind: Sendable {
        case perCallSite
        case unlimited
        case storage(BudgetStorage)
    }

    let kind: Kind

    /// One budget per call site, shared by every retry made from that line. The default.
    public static let perCallSite = RetryBudget(kind: .perCallSite)

    /// No budget: retries are limited only by their schedule. Use with care.
    public static let unlimited = RetryBudget(kind: .unlimited)

    private init(kind: Kind) {
        self.kind = kind
    }

    /// A new budget, not shared with anything that does not hold this value.
    public init(ratio: Double = 0.2, reservePerSecond: Double = 1, reserveCapacity: Double = 10) {
        self.kind = .storage(BudgetStorage(ratio: ratio, reservePerSecond: reservePerSecond, reserveCapacity: reserveCapacity))
    }

    /// The process-wide budget called `name`, created with the default
    /// settings the first time it is asked for. Use one name per dependency:
    /// `RetryBudget.named("api.example.com")`.
    public static func named(_ name: String) -> RetryBudget {
        RetryBudget(kind: .storage(BudgetRegistry.shared.budget(named: name)))
    }

    /// The tokens available right now, earned and reserve together.
    public var available: Double? {
        guard case .storage(let storage) = kind else { return nil }
        return storage.available(clock: Ambient.current.clock)
    }

    /// Resolves the per-call-site default to the budget for that site.
    func resolved(fileID: String, line: UInt) -> BudgetStorage? {
        switch kind {
        case .perCallSite: BudgetRegistry.shared.budget(named: "\(fileID):\(line)")
        case .unlimited: nil
        case .storage(let storage): storage
        }
    }

    public var description: String {
        switch kind {
        case .perCallSite: "RetryBudget.perCallSite"
        case .unlimited: "RetryBudget.unlimited"
        case .storage(let storage): "RetryBudget(\(storage.settings))"
        }
    }
}

/// The shared token state behind a ``RetryBudget``.
final class BudgetStorage: Sendable {
    struct Settings: Sendable, CustomStringConvertible {
        let ratio: Double
        let reservePerSecond: Double
        let reserveCapacity: Double

        var description: String {
            "ratio: \(ratio), reserve: \(reservePerSecond)/s up to \(reserveCapacity)"
        }
    }

    private struct State {
        var earned: Double = 0
        var reserve: Double
        // The clock the last refill was measured on. Instants from another
        // clock (a test clock replacing the real one) are not comparable,
        // so a change of clock restarts the refill measurement.
        var refilledAt: (instant: AnyClock.Instant, clock: AnyClock)?
    }

    let settings: Settings
    private let state: Mutex<State>

    init(ratio: Double, reservePerSecond: Double, reserveCapacity: Double) {
        precondition(ratio >= 0 && reservePerSecond >= 0 && reserveCapacity >= 0, "budget settings must not be negative")
        settings = Settings(ratio: ratio, reservePerSecond: reservePerSecond, reserveCapacity: reserveCapacity)
        state = Mutex(State(reserve: reserveCapacity))
    }

    /// Records a first attempt.
    func deposit() {
        state.withLock { state in
            // Earned tokens are capped so a long quiet success streak cannot
            // bank an unbounded burst of retries for the next outage.
            state.earned = min(state.earned + settings.ratio, max(1, settings.reserveCapacity))
        }
    }

    /// Spends a token for one retry, if there is one.
    func withdraw(clock: AnyClock) -> Bool {
        state.withLock { state in
            refill(&state, clock: clock)
            if state.earned >= 1 {
                state.earned -= 1
                return true
            }
            if state.reserve >= 1 {
                state.reserve -= 1
                return true
            }
            return false
        }
    }

    func available(clock: AnyClock) -> Double {
        state.withLock { state in
            refill(&state, clock: clock)
            return state.earned + state.reserve
        }
    }

    private func refill(_ state: inout State, clock: AnyClock) {
        let now = clock.now
        defer { state.refilledAt = (now, clock) }
        guard let last = state.refilledAt, last.clock.isSameClock(as: clock) else { return }
        let elapsed = max(.zero, last.instant.duration(to: now))
        state.reserve = min(settings.reserveCapacity, state.reserve + elapsed.seconds * settings.reservePerSecond)
    }
}

/// Named budgets, process-wide.
final class BudgetRegistry: Sendable {
    static let shared = BudgetRegistry()

    private let budgets = Mutex<[String: BudgetStorage]>([:])

    func budget(named name: String) -> BudgetStorage {
        budgets.withLock { budgets in
            if let existing = budgets[name] { return existing }
            let created = BudgetStorage(ratio: 0.2, reservePerSecond: 1, reserveCapacity: 10)
            budgets[name] = created
            return created
        }
    }
}
