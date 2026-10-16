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
/// refused and the last error is rethrown. Tokens are counted in exact
/// thousandths, so ten deposits of 0.1 make exactly one token.
///
/// Budgets live in the ambient ``RetryBudgets`` registry, so a test that
/// installs a fresh registry (`withTestAmbient`) starts with full budgets
/// and cannot be affected by another test's retries.
public struct RetryBudget: Sendable, CustomStringConvertible {
    enum Kind: Sendable {
        case perCallSite
        case named(String)
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

    /// A new budget, shared only by whoever holds this value.
    public init(ratio: Double = 0.2, reservePerSecond: Double = 1, reserveCapacity: Double = 10) {
        self.kind = .storage(BudgetStorage(settings: .init(ratio: ratio, reservePerSecond: reservePerSecond, reserveCapacity: reserveCapacity)))
    }

    /// The budget called `name` in the ambient registry, created with the
    /// default settings the first time it is used. Use one name per
    /// dependency: `.named("api.example.com")`.
    public static func named(_ name: String) -> RetryBudget {
        RetryBudget(kind: .named(name))
    }

    /// The tokens available right now, earned and reserve together, or `nil`
    /// for an unlimited budget.
    public func available(fileID: String = #fileID, line: UInt = #line) -> Double? {
        let ambient = Ambient.current
        return resolved(fileID: fileID, line: line, registry: ambient.budgets)?.available(clock: ambient.clock)
    }

    func resolved(fileID: String, line: UInt, registry: RetryBudgets) -> BudgetStorage? {
        switch kind {
        case .perCallSite: registry.storage(for: .site(fileID, line))
        case .named(let name): registry.storage(for: .name(name))
        case .unlimited: nil
        case .storage(let storage): storage
        }
    }

    public var description: String {
        switch kind {
        case .perCallSite: "RetryBudget.perCallSite"
        case .named(let name): "RetryBudget.named(\(name))"
        case .unlimited: "RetryBudget.unlimited"
        case .storage(let storage): "RetryBudget(\(storage.settings))"
        }
    }
}

/// The registry of shared retry budgets: per-call-site and named ones.
///
/// One lives in ``Ambient/budgets``. The process-wide default is shared by
/// everything; a test installs a fresh one so its budgets start full. The
/// registry holds at most 4,096 budgets, forgetting the least recently
/// created beyond that, so dynamically generated names cannot grow it without
/// bound.
public final class RetryBudgets: Sendable {
    /// The process-wide registry.
    public static let shared = RetryBudgets()

    static let limit = 4_096

    private struct State {
        var budgets: [Key: BudgetStorage] = [:]
        var order: [Key] = []
    }

    private let state = Mutex(State())
    private let defaults: BudgetStorage.Settings

    /// A fresh registry whose budgets are created with these settings.
    public init(ratio: Double = 0.2, reservePerSecond: Double = 1, reserveCapacity: Double = 10) {
        defaults = .init(ratio: ratio, reservePerSecond: reservePerSecond, reserveCapacity: reserveCapacity)
    }

    /// A budget's identity: a name, or a call site. A structured key, so the
    /// per-call-site default costs no string building on every retry.
    enum Key: Hashable {
        case name(String)
        case site(String, UInt)
    }

    func storage(for key: Key) -> BudgetStorage {
        state.withLock { state in
            if let existing = state.budgets[key] { return existing }
            let created = BudgetStorage(settings: defaults)
            state.budgets[key] = created
            state.order.append(key)
            if state.order.count > Self.limit {
                state.budgets[state.order.removeFirst()] = nil
            }
            return created
        }
    }
}

/// The shared token state behind a ``RetryBudget``, in thousandths of a token.
final class BudgetStorage: Sendable {
    struct Settings: Sendable, CustomStringConvertible {
        let ratio: Int64
        let reservePerSecond: Int64
        let reserveCapacity: Int64

        init(ratio: Double, reservePerSecond: Double, reserveCapacity: Double) {
            precondition(ratio >= 0 && reservePerSecond >= 0 && reserveCapacity >= 0, "budget settings must not be negative")
            self.ratio = Int64((ratio * 1000).rounded())
            self.reservePerSecond = Int64((reservePerSecond * 1000).rounded())
            self.reserveCapacity = Int64((reserveCapacity * 1000).rounded())
        }

        var description: String {
            "ratio: \(Double(ratio) / 1000), reserve: \(Double(reservePerSecond) / 1000)/s up to \(Double(reserveCapacity) / 1000)"
        }
    }

    private struct State {
        var earned: Int64 = 0
        var reserve: Int64
        // The clock the last refill was measured on. Instants from another
        // clock (a test clock replacing the real one) are not comparable,
        // so a change of clock restarts the refill measurement.
        var refilledAt: (instant: AnyClock.Instant, clock: AnyClock)?
    }

    let settings: Settings
    private let state: Mutex<State>

    init(settings: Settings) {
        self.settings = settings
        state = Mutex(State(reserve: settings.reserveCapacity))
    }

    /// Records a first attempt.
    func deposit() {
        state.withLock { state in
            // Earned tokens are capped at one reserve's worth so that a long
            // success streak cannot bank an unbounded burst for the next outage.
            state.earned = min(state.earned + settings.ratio, max(1000, settings.reserveCapacity))
        }
    }

    /// Which kind of token a withdrawal spent, so a refund returns it there.
    enum Token: Sendable {
        case earned
        case reserve
    }

    /// Spends a token for one retry, if there is one.
    func withdraw(clock: AnyClock) -> Token? {
        state.withLock { state in
            refill(&state, clock: clock)
            if state.earned >= 1000 {
                state.earned -= 1000
                return .earned
            }
            if state.reserve >= 1000 {
                state.reserve -= 1000
                return .reserve
            }
            return nil
        }
    }

    /// Returns a token spent on a retry that never happened (its caller was
    /// cancelled during the backoff), within the usual limits.
    func refund(_ token: Token) {
        state.withLock { state in
            switch token {
            case .earned: state.earned = min(state.earned + 1000, max(1000, settings.reserveCapacity))
            case .reserve: state.reserve = min(state.reserve + 1000, settings.reserveCapacity)
            }
        }
    }

    func available(clock: AnyClock) -> Double {
        state.withLock { state in
            refill(&state, clock: clock)
            return Double(state.earned + state.reserve) / 1000
        }
    }

    private func refill(_ state: inout State, clock: AnyClock) {
        let now = clock.now
        guard let last = state.refilledAt, last.clock.isSameClock(as: clock) else {
            state.refilledAt = (now, clock)
            return
        }
        let elapsed = max(.zero, last.instant.duration(to: now))
        let gained = Int64(min(Double(Int64.max / 2), (elapsed.seconds * Double(settings.reservePerSecond)).rounded(.down)))
        guard gained > 0 else { return }   // keep the old instant: sub-token time accrues
        state.reserve = min(settings.reserveCapacity, state.reserve + gained)
        state.refilledAt = (now, clock)
    }
}
