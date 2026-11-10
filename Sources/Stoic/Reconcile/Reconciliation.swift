/// Two systems, one of them the truth, and how to bring the other into line
/// (design/30).
///
/// A conforming type is the declaration; an instance holds the clients it
/// reads and writes through. Nothing writes both sides: the code that changes
/// the facts writes only the truth, and a ``Reconciler`` is the only writer of
/// the derived side's keys. It reads what the truth says the derived side
/// should hold and what it holds, and applies the difference as corrections
/// that are safe to repeat.
///
///     struct CalendarAttendees: Reconciliation {
///         static let name = "kindora.calendar-attendees"
///         static let readsTruth = Backend.database.readOnly("calendar.desired")
///         static let readsDerived = Backend.calendar.readOnly("events.list")
///         static let corrects = Backend.calendar.idempotent("events.put")
///
///         func desired(_ scope: ReconcileScope<EventID>, attempt: Attempt) async throws(KindoraError) -> [EventID: Listing] { … }
///         func actual(_ scope: ReconcileScope<EventID>, attempt: Attempt) async throws(KindoraError) -> [EventID: Listing] { … }
///         func correct(_ correction: Correction<EventID, Listing, Listing>, attempt: Attempt) async throws(KindoraError) { … }
///     }
///
/// **Each read is complete or it throws.** That is the rule that keeps a
/// failed read from deleting anything: a paged read whose third page fails
/// throws, and never returns the first two.
public protocol Reconciliation: Sendable {
    /// What a correction is addressed by: an event's id, a device's id.
    /// `Comparable`, so a pass is deterministic: keys are compared, corrected,
    /// deferred and reported in key order.
    associatedtype Key: Hashable & Comparable & Sendable
    /// What the truth says one key of the derived side should hold.
    associatedtype Desired: Sendable
    /// What one key of the derived side holds.
    associatedtype Actual: Sendable
    /// How a read or a correction fails.
    associatedtype Failure: Error

    /// Stable forever: it names the reconciliation in events and keys.
    static var name: String { get }
    /// How the truth is read. Must be `.readOnly`.
    static var readsTruth: Backend.Operation { get }
    /// How the derived side is read. Must be `.readOnly`.
    static var readsDerived: Backend.Operation { get }
    /// How a correction is applied. Must be `.idempotent` or `.keyed`.
    static var corrects: Backend.Operation { get }

    /// What the truth says the derived side should hold within `scope`:
    /// complete, or thrown. A key absent from the result must not exist there.
    func desired(_ scope: ReconcileScope<Key>, attempt: Attempt) async throws(Failure) -> [Key: Desired]

    /// What the derived side holds within `scope`: complete, or thrown.
    func actual(_ scope: ReconcileScope<Key>, attempt: Attempt) async throws(Failure) -> [Key: Actual]

    /// Whether the derived side's value is what the truth asks for. `==` by
    /// default when `Desired` and `Actual` are one `Equatable` type.
    func matches(_ desired: Desired, _ actual: Actual) -> Bool

    /// Makes one key of the derived side match. It must leave the same result
    /// whether run once or more, and whatever the key's state was: a `PUT` or a
    /// delete addressed by the truth's key, never a toggle.
    func correct(_ correction: Correction<Key, Desired, Actual>, attempt: Attempt) async throws(Failure)

    /// When the truth will next change by itself (an event ends, a record
    /// falls due): a pass runs then. `nil` by default.
    func nextChange() async -> Moment?
}

extension Reconciliation where Desired == Actual, Desired: Equatable {
    public func matches(_ desired: Desired, _ actual: Actual) -> Bool {
        desired == actual
    }
}

extension Reconciliation {
    public func nextChange() async -> Moment? {
        nil
    }
}

/// Which keys a pass reads.
public enum ReconcileScope<Key: Hashable & Sendable>: Sendable, Hashable {
    /// Every key either side holds.
    case all
    /// These keys only.
    case keys(Set<Key>)

    /// Whether `key` is in the scope.
    public func contains(_ key: Key) -> Bool {
        switch self {
        case .all: true
        case .keys(let keys): keys.contains(key)
        }
    }
}

/// One change that makes one key of the derived side match the truth.
public enum Correction<Key: Sendable, Desired: Sendable, Actual: Sendable>: Sendable {
    /// The truth has it; the derived side does not.
    case create(Key, Desired)
    /// Both have it, and it does not match.
    case update(Key, Desired, was: Actual)
    /// The derived side has it; the truth does not.
    case remove(Key, was: Actual)

    /// The key it corrects.
    public var key: Key {
        switch self {
        case .create(let key, _), .update(let key, _, _), .remove(let key, _): key
        }
    }

    /// Which kind of correction it is.
    public var kind: CorrectionKind {
        switch self {
        case .create: .create
        case .update: .update
        case .remove: .remove
        }
    }
}

/// Which kind a correction is; ordered as a plan orders them.
public enum CorrectionKind: String, Sendable, Hashable, Comparable {
    case create, update, remove

    private var rank: Int {
        switch self {
        case .create: 0
        case .update: 1
        case .remove: 2
        }
    }

    public static func < (lhs: CorrectionKind, rhs: CorrectionKind) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// The difference between two complete readings, as data. Pure.
///
/// | truth  | derived | `matches` | correction                           |
/// | ------ | ------- | --------- | ------------------------------------ |
/// | has it | lacks   | —         | `.create(key, desired)`              |
/// | has it | has it  | false     | `.update(key, desired, was: actual)` |
/// | has it | has it  | true      | none (`unchanged`)                   |
/// | lacks  | has it  | —         | `.remove(key, was: actual)`          |
///
/// Creates and updates come first, by key, then removes, by key: the work
/// that adds is done first, the guard judges the removals, and a pass cut
/// short has done the safe work.
public struct ReconcilePlan<R: Reconciliation>: Sendable {
    /// Every correction, creates and updates by key, then removes by key.
    public let corrections: [Correction<R.Key, R.Desired, R.Actual>]
    /// Keys both readings hold and that match.
    public let unchanged: Int

    public init(desired: [R.Key: R.Desired], actual: [R.Key: R.Actual], using reconciliation: R) {
        var adds: [Correction<R.Key, R.Desired, R.Actual>] = []
        var unchanged = 0
        for (key, wanted) in desired.sorted(by: { $0.key < $1.key }) {
            if let held = actual[key] {
                if reconciliation.matches(wanted, held) {
                    unchanged += 1
                } else {
                    adds.append(.update(key, wanted, was: held))
                }
            } else {
                adds.append(.create(key, wanted))
            }
        }
        var removes: [Correction<R.Key, R.Desired, R.Actual>] = []
        for (key, held) in actual.sorted(by: { $0.key < $1.key }) where desired[key] == nil {
            removes.append(.remove(key, was: held))
        }
        corrections = adds + removes
        self.unchanged = unchanged
    }

    /// How many of the corrections are removals.
    public var removals: Int {
        corrections.count { $0.kind == .remove }
    }
}

/// How much of the derived side one pass may remove without a person.
public struct RemovalGuard: Sendable, Hashable, CustomStringConvertible {
    private enum Rule: Hashable {
        case share(Double, count: Int)
        case unguarded
    }

    private let rule: Rule

    /// A pass may remove at most `max(count, ⌊share × derived keys read⌋)`
    /// keys, and a full pass that read an empty truth beside a derived side
    /// that is not empty removes nothing.
    public static func atMost(share: Double, orCount count: Int) -> RemovalGuard {
        precondition(share >= 0 && share <= 1, "a removal guard's share is between 0 and 1")
        precondition(count >= 0, "a removal guard's count is not negative")
        return RemovalGuard(rule: .share(share, count: count))
    }

    /// Removals are never held: a derived side that is a cache of nothing
    /// anyone needs.
    public static let unguarded = RemovalGuard(rule: .unguarded)

    /// Whether the guard holds nothing.
    var isUnguarded: Bool { rule == .unguarded }

    /// How many removals a pass over `derived` keys may make; `nil` when any
    /// number may.
    func limit(derived: Int) -> Int? {
        switch rule {
        case .unguarded: nil
        case .share(let share, let count): max(count, Int((share * Double(derived)).rounded(.down)))
        }
    }

    public var description: String {
        switch rule {
        case .unguarded: "unguarded"
        case .share(let share, let count): "at most \(share) or \(count)"
        }
    }
}

/// Removals a pass did not make, waiting for a person.
public struct RemovalHold<Key: Hashable & Sendable & Comparable>: Sendable, Hashable {
    /// Every key the pass would have removed, in key order.
    public let keys: [Key]
    /// How many: `keys.count`.
    public var removals: Int { keys.count }
    /// The derived keys the pass that made the hold read.
    public let derivedCount: Int
    /// Whether a full pass read an empty truth.
    public let truthWasEmpty: Bool
    /// When it was first held.
    public let since: Moment
}

/// The numbers a reconciler runs by. Each default is design/30's, with its
/// reason there.
public struct ReconcilePolicy: Sendable, Hashable {
    /// How much one pass may remove without a person: 10% of what was read, or 5.
    public var removals: RemovalGuard = .atMost(share: 0.10, orCount: 5)
    /// The most corrections one pass starts; the rest follow after `coalesce`.
    public var correctionsPerPass: Int = 1_000
    /// The most corrections in flight at once.
    public var concurrency: Int = 4
    /// The longest one pass may take.
    public var passDeadline: Duration = .seconds(600)
    /// Quiet time before a triggered pass.
    public var coalesce: Duration = .seconds(1)
    /// When a scoped pass reads back what a pass corrected.
    public var verifyAfter: Duration = .seconds(2)
    /// Passes in a row a key may fail to converge before it is stuck.
    public var stuckAfter: Int = 3
    /// How long a key that failed waits before it is corrected again.
    public var keyBackoff: Schedule = .exponential(base: .seconds(5)).capped(at: .seconds(3_600))
    /// How long after a pass that could not read a side the next one runs;
    /// never longer than the schedule's delay.
    public var failedPassBackoff: Schedule = .exponential(base: .seconds(30)).capped(at: .seconds(900))
    /// Triggered keys held before a full pass replaces them.
    public var pendingKeys: Int = 10_000
    /// How long without a full pass before the reconciler is overdue.
    public var overdueAfter: Duration = .seconds(1_800)
    /// The urgency of `run()`'s passes; `pass()` keeps its caller's.
    public var urgency: Urgency = .utility

    public init() {}
}
