public import Stoic

/// A ``LifecycleStore`` in memory, for tests: what a server's database does
/// in one transaction, done in one actor turn.
///
///     let waivers = InMemoryLifecycleStore<ParentWaiver, String>()
///     _ = try await waivers.insert(.new(in: .awaitingAddress, by: .staff(admin), because: "minor signed up"), as: "w1")
///     try await waivers.apply(.send(to: parent), to: "w1", by: .staff(admin), because: "address confirmed")
///     #expect(await waivers.effects.map(\.effect) == [.emailSigningLink(to: parent)])
///
/// Every effect committed is kept in ``effects``, in commit order, as a
/// server's outbox table would hold it. ``conflictNextCommit(to:times:)``
/// makes the next commits to a record lose to a writer that never was, for
/// the conflict rows.
public actor InMemoryLifecycleStore<L: Lifecycle, ID: Hashable & Sendable>: LifecycleStore {
    public typealias Definition = L

    /// Why the store refused a commit.
    public enum Failure: Error, Sendable, Hashable {
        /// The change was made from another record: its key is not the
        /// stored record's.
        case foreignChange
        /// The change is not one the record could have made: its revision,
        /// sequence or entries do not follow the stored record.
        case malformedChange
    }

    private var records: [ID: L.Record] = [:]
    private var histories: [ID: [L.Entry]] = [:]
    private var committedEffects: [LifecycleEffect<L>] = []
    private var conflicts: [ID: Int] = [:]

    public init() {}

    /// Every effect committed, in commit order.
    public var effects: [LifecycleEffect<L>] { committedEffects }

    /// Makes the next `times` commits to `id` return a conflict without
    /// writing anything, as if another writer had just committed.
    public func conflictNextCommit(to id: ID, times: Int = 1) {
        conflicts[id, default: 0] += times
    }

    /// `now`: like a server's store, this one reads at the moment it is given.
    public func moment(for now: Moment) -> Moment {
        now
    }

    public func load(_ id: ID) -> L.Record? {
        records[id]
    }

    public func history(of id: ID) -> [L.Entry] {
        histories[id] ?? []
    }

    public func insert(_ record: L.Record, as id: ID) -> Bool {
        guard records[id] == nil else { return false }
        records[id] = record
        histories[id] = []
        return true
    }

    public func commit(_ change: L.Change, to id: ID) throws(Failure) -> LifecycleCommit<L> {
        guard let current = records[id] else { return .conflict(current: nil) }
        guard current.key == change.record.key else { throw .foreignChange }
        if let pending = conflicts[id], pending > 0 {
            conflicts[id] = pending - 1
            return .conflict(current: current)
        }
        guard current.revision == change.base else { return .conflict(current: current) }
        guard change.follows(current) else { throw .malformedChange }
        records[id] = change.record
        histories[id, default: []].append(contentsOf: change.entries)
        committedEffects.append(contentsOf: change.effects)
        return .committed
    }
}
