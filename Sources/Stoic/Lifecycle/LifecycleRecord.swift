/// A lifecycle's record at rest: a value holding the state as written, when
/// it was entered, and a revision.
///
///     let record = ParentWaiver.Record.new(in: .awaitingAddress, by: .staff(admin), because: "minor signed up")
///     let change = try record.applying(.send(to: parent), by: .staff(admin), because: "address confirmed")
///     // commit `change` to a store; then, a week later, anywhere:
///     change.record.state()        // .expired, though nobody wrote it
///
/// **Reading applies what has fallen due.** ``read(at:)`` starts from the
/// written state and applies every timeout due by `now`, so an expired
/// waiver is `.expired` to every path that reads it, whether or not anything
/// wrote it. There is no `state` property that skips the timeouts: the state
/// as stored is ``Written/state``, named for what it is, for indexes and
/// never for decisions.
///
/// **Nothing is written by a read.** Reading, applying and settling are pure
/// functions of the record, the definition and a moment. A projected
/// transition becomes a fact, with history and effects, when a change that
/// carries it is committed to a ``LifecycleStore``.
///
/// **The encoded form is fixed**, so database columns and other languages can
/// rely on it: `lifecycle` (the definition's name, checked on decode),
/// `version`, `key`, `revision`, `sequence`, `created` (`at`, `by`,
/// `because`), `state`, `since`, `updated`, and `dueAt` (written for indexes,
/// ignored on decode: it is derived). Moments are RFC 3339 text.
public struct LifecycleRecord<L: Lifecycle>: Sendable, Hashable, Codable {
    /// How the record began. Creation is not a transition, so it is not a
    /// history entry.
    public struct Creation: Sendable, Hashable, Codable {
        public let at: Moment
        public let by: Initiator<L.Principal>
        public let because: String
    }

    /// The state as stored: for indexes and queries, never for decisions,
    /// since a timeout may have fallen due since it was written.
    public struct Written: Sendable, Hashable {
        /// The state the last commit left.
        public let state: L.State
        /// When that state was entered.
        public let since: Moment
        /// The latest history entry's moment, or creation's.
        public let updated: Moment
        /// When the state's timeout falls due, by the definition in force:
        /// `since + d` for `.after(d)`, `m` for `.at(m)`, `nil` for none. A
        /// query for records that may have timed out filters on it.
        public let dueAt: Moment?
    }

    /// 128 random bits from the ambient random source at creation: the root
    /// of every effect key, so keys are unique across stores and
    /// unpredictable.
    public let key: IdempotencyKey
    /// 1 at creation, and 1 more for each commit, however many entries it
    /// holds: the compare-and-set token.
    public let revision: UInt64
    /// How many history entries have been committed: the next entry's
    /// number.
    public let sequence: UInt64
    /// When, by whom and why the record was made.
    public let created: Creation
    /// The ``Lifecycle/version`` of the definition that last wrote it.
    public let version: Int

    let state: L.State
    let since: Moment
    let updated: Moment

    init(
        key: IdempotencyKey, revision: UInt64, sequence: UInt64, created: Creation, version: Int,
        state: L.State, since: Moment, updated: Moment
    ) {
        self.key = key
        self.revision = revision
        self.sequence = sequence
        self.created = created
        self.version = version
        self.state = state
        self.since = since
        self.updated = updated
    }

    /// A new record in `state`, made `at` by `by`.
    ///
    /// Any state will do, because importing existing data is creation too:
    /// a checked-out commitment becomes a record in `.checkedOut`, `because:
    /// "imported from commitments"`.
    ///
    /// - Parameters:
    ///   - state: The state the record starts in.
    ///   - by: Who made it.
    ///   - because: Why, in a short sentence kept with the record and never
    ///     in an event (it may name people).
    ///   - at: When; the ambient wall clock's now by default.
    public static func new(in state: L.State, by: L.Principal, because: String, at: Moment = .now) -> Self {
        new(in: state, by: by, because: because, at: at, key: .random())
    }

    /// ``new(in:by:because:at:)`` with a key the caller chose: for a test
    /// that needs records it can name, and for walks that must not draw from
    /// the ambient source.
    package static func new(in state: L.State, by: L.Principal, because: String, at: Moment, key: IdempotencyKey) -> Self {
        Self(
            key: key, revision: 1, sequence: 0, created: Creation(at: at, by: .principal(by), because: because),
            version: L.version, state: state, since: at, updated: at)
    }

    /// The state as stored, and when its timeout falls due.
    public var written: Written {
        Written(state: state, since: since, updated: updated, dueAt: L.timeout(in: state)?.due(since: since))
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case lifecycle, version, key, revision, sequence, created, state, since, updated, dueAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .lifecycle)
        guard name == L.name else {
            throw DecodingError.dataCorruptedError(
                forKey: .lifecycle, in: container,
                debugDescription: "a record of \(name), not of \(L.name)")
        }
        version = try container.decode(Int.self, forKey: .version)
        key = try container.decode(IdempotencyKey.self, forKey: .key)
        revision = try container.decode(UInt64.self, forKey: .revision)
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        created = try container.decode(Creation.self, forKey: .created)
        state = try container.decode(L.State.self, forKey: .state)
        since = try container.decode(Moment.self, forKey: .since)
        updated = try container.decode(Moment.self, forKey: .updated)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(L.name, forKey: .lifecycle)
        try container.encode(version, forKey: .version)
        try container.encode(key, forKey: .key)
        try container.encode(revision, forKey: .revision)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(created, forKey: .created)
        try container.encode(state, forKey: .state)
        try container.encode(since, forKey: .since)
        try container.encode(updated, forKey: .updated)
        try container.encodeIfPresent(written.dueAt, forKey: .dueAt)
    }
}

/// One entry of a record's history: a transition, a `.stay`, or a timeout
/// that fell due, with who and why.
///
/// Entries are numbered from 0 with no gap, and written once, beside the
/// record, never rewritten. Encoded as `record`, `sequence`, `from`,
/// `event`, `to`, `entered`, `at`, `by` (`{"principal": …}` or
/// `"timeout"`), `because` and `effects`.
public struct LifecycleEntry<L: Lifecycle>: Sendable, Hashable, Codable {
    /// The key of the record it belongs to.
    public let record: IdempotencyKey
    /// Its place in the record's history: 0, 1, 2, … with no gap.
    public let sequence: UInt64
    public let from: L.State
    public let event: L.Event
    public let to: L.State
    /// Whether the state was entered (`false` for a `.stay`, whose `from`
    /// and `to` are the same and whose timeout kept running).
    public let entered: Bool
    /// When it happened: the moment the event was applied, or the moment
    /// the timeout fell due; never earlier than the entry before it.
    public let at: Moment
    public let by: Initiator<L.Principal>
    /// Why: the caller's sentence, or the timeout's description
    /// (`after 604800 s`).
    public let because: String
    /// The keys of the effects this entry carried, in order.
    public let effects: [IdempotencyKey]
}

/// What committing would write: a new head, history entries, and effects
/// with their keys.
///
/// Made by ``LifecycleRecord/applying(_:by:because:at:)`` and
/// ``LifecycleRecord/settling(at:)``; a store commits it only over the
/// revision it was made from (``base``).
public struct LifecycleChange<L: Lifecycle>: Sendable {
    /// The revision it was made from: it commits only over this.
    public let base: UInt64
    /// The record after it: `revision == base + 1`.
    public let record: L.Record
    /// The entries it adds, timed entries first, then the event's.
    public let entries: [L.Entry]
    /// The effects its entries carry, in order, each with its key.
    public let effects: [LifecycleEffect<L>]

    /// The moment it was made at.
    package let at: Moment
    /// How far the event's entry was raised to the record's latest moment,
    /// when the moment it was made at was earlier.
    package let clockBehind: Duration?
    /// The event of the state's own timeout, when it fell due and did not
    /// move the state (a defective definition).
    package let refusedTimeout: L.Event?
}

/// One effect a committed change owes, with the key it is delivered under.
public struct LifecycleEffect<L: Lifecycle>: Sendable, Codable {
    /// Derived from the record's key, the entry's sequence and the effect's
    /// position (``IdempotencyKey/lifecycle(record:entry:position:)``):
    /// making the same change twice gives the same key.
    public let key: IdempotencyKey
    public let effect: L.Effect
    /// The key of the record whose entry carried it.
    public let record: IdempotencyKey
    /// The sequence of the entry that carried it.
    public let entry: UInt64
}

/// Why an event was not applied, or a record not settled. Nothing changed.
public enum LifecycleRefusal<L: Lifecycle>: Error, Sendable, Hashable {
    /// The definition refused the event in `state`, with a reason for the
    /// caller to tell a person.
    case refused(state: L.State, event: L.Event, reason: String)
    /// The event means nothing in `state`.
    case ignored(state: L.State, event: L.Event)
    /// The definition says the event is impossible in `state`: a bug.
    case invalid(state: L.State, event: L.Event, reason: String)
    /// The record was written by a newer definition (`written`) than this
    /// one (`current`): an older definition never writes over it.
    case newerDefinition(written: Int, current: Int)
    /// Timed steps stopped at their cap in `state`: the definition's
    /// timeouts form a cycle (`StateGraph.timedCycles` finds it).
    case chainTooLong(state: L.State, steps: Int)
}

extension LifecycleRefusal: Retryable {
    /// Never retried: the same record and event refuse the same way.
    public var retryDecision: RetryDecision { .stop }
}

extension LifecycleChange {
    /// Whether this change follows `current` as a change made from it must:
    /// one revision on, its entries numbered on from the record's, each the
    /// record's. (Whether it was made from `current` at all is its key's
    /// question, and whether it commits over it its ``base``'s.)
    package func follows(_ current: L.Record) -> Bool {
        guard record.revision == base + 1, record.key == current.key,
            record.sequence == current.sequence + UInt64(entries.count)
        else { return false }
        for (offset, entry) in entries.enumerated()
        where entry.sequence != current.sequence + UInt64(offset) || entry.record != current.key {
            return false
        }
        return true
    }
}
