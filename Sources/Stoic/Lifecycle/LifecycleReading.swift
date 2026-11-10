/// What a record is at a moment: the state its due timeouts lead to, and
/// the entries that would make it so.
public struct LifecycleReading<L: Lifecycle>: Sendable {
    /// The state, with every timeout due by the moment read applied.
    public let state: L.State
    /// When that state was entered.
    public let since: Moment
    /// Timed entries due and not yet committed, oldest first: what a commit
    /// would add before anything else.
    public let pending: [L.Entry]
    /// When the current state's timeout falls due, if it has one. A moment
    /// at or before the one read means a defective definition: the chain
    /// was truncated, or the timeout does not move the state.
    public let nextDue: Moment?
    /// Whether timed steps stopped at their cap (64): a defective
    /// definition whose timeouts form a cycle.
    public let isTruncated: Bool
    /// The event of the state's own timeout, when it fell due and did not
    /// move the state.
    package let refusedTimeout: L.Event?

    /// Whether ``state`` is final.
    public var isFinal: Bool { L.isFinal(state) }
}

extension LifecycleRecord {
    /// The most timed steps one reading applies. Far above any definition
    /// whose timeouts form no cycle; a defect costs a refusal, never a hang.
    public static var timedStepLimit: Int { 64 }

    /// The record at `now`: the written state, with every timeout that has
    /// fallen due applied in order, each as if sent at its due moment.
    ///
    /// Nothing is written and nothing is reported: a read is a pure
    /// function, safe in views, queries and previews.
    ///
    /// - Parameter now: The moment to read at; the ambient wall clock's by
    ///   default, so tests and replays pin it.
    public func read(at now: Moment = .now) -> LifecycleReading<L> {
        let projection = project(at: now)
        return LifecycleReading(
            state: projection.state, since: projection.since, pending: projection.entries,
            nextDue: L.timeout(in: projection.state)?.due(since: projection.since),
            isTruncated: projection.truncated, refusedTimeout: projection.refusedTimeout)
    }

    /// The state at `now`: ``read(at:)``'s.
    public func state(at now: Moment = .now) -> L.State {
        project(at: now).state
    }

    /// The change that applying `event` at `now` would commit: the timeouts
    /// due by `now` first, then the event's entry.
    ///
    /// It never does nothing silently: it returns a change, or throws a
    /// refusal that names the state the event met. A `.stay` is history
    /// too, and moves the revision.
    ///
    /// - Parameters:
    ///   - event: What happened.
    ///   - by: Who did it.
    ///   - because: Why, in a short sentence kept in history and never in
    ///     an event (it may name people). Empty is accepted.
    ///   - now: When; the ambient wall clock's now by default. An entry is
    ///     never dated before the record's latest moment: a clock behind it
    ///     is raised to it.
    /// - Throws: ``LifecycleRefusal``: the definition refused, ignored or
    ///   declared the event invalid in the state reached; the record was
    ///   written by a newer definition; or the timed steps reached their cap.
    public func applying(
        _ event: L.Event, by: L.Principal, because: String, at now: Moment = .now
    ) throws(L.Refusal) -> L.Change {
        try checkVersion()
        var projection = project(at: now)
        if projection.truncated { throw .chainTooLong(state: projection.state, steps: Self.timedStepLimit) }
        let at = max(now, projection.updated)
        let clockBehind = now < projection.updated ? now.duration(to: projection.updated) : nil
        switch L.transition(from: projection.state, on: event) {
        case .to(let next, let effects):
            projection.add(
                from: projection.state, event: event, to: next, entered: true, at: at, by: .principal(by),
                because: because, effects: effects, record: key)
        case .stay(let effects):
            projection.add(
                from: projection.state, event: event, to: projection.state, entered: false, at: at,
                by: .principal(by), because: because, effects: effects, record: key)
        case .refuse(let reason):
            throw .refused(state: projection.state, event: event, reason: reason)
        case .ignore:
            throw .ignored(state: projection.state, event: event)
        case .invalid(let reason):
            throw .invalid(state: projection.state, event: event, reason: reason)
        }
        return change(from: projection, at: now, clockBehind: clockBehind)
    }

    /// The change that commits the timeouts due by `now`, or `nil` when
    /// nothing is due.
    ///
    /// - Throws: ``LifecycleRefusal/newerDefinition(written:current:)`` or
    ///   ``LifecycleRefusal/chainTooLong(state:steps:)``.
    public func settling(at now: Moment = .now) throws(L.Refusal) -> L.Change? {
        try checkVersion()
        let projection = project(at: now)
        if projection.truncated { throw .chainTooLong(state: projection.state, steps: Self.timedStepLimit) }
        guard !projection.entries.isEmpty else { return nil }
        return change(from: projection, at: now, clockBehind: nil)
    }

    private func checkVersion() throws(L.Refusal) {
        guard version <= L.version else { throw .newerDefinition(written: version, current: L.version) }
    }

    private func change(from projection: Projection, at now: Moment, clockBehind: Duration?) -> L.Change {
        let next = LifecycleRecord(
            key: key, revision: revision + 1, sequence: projection.sequence, created: created, version: L.version,
            state: projection.state, since: projection.since, updated: projection.updated)
        return LifecycleChange(
            base: revision, record: next, entries: projection.entries, effects: projection.effects, at: now,
            clockBehind: clockBehind, refusedTimeout: projection.refusedTimeout)
    }

    // MARK: Projection

    /// The record carried forward: entries and effects that a commit would
    /// add, and the head they would leave.
    struct Projection {
        var state: L.State
        var since: Moment
        var updated: Moment
        var sequence: UInt64
        var entries: [L.Entry] = []
        var effects: [LifecycleEffect<L>] = []
        var truncated = false
        var refusedTimeout: L.Event?

        mutating func add(
            from: L.State, event: L.Event, to: L.State, entered: Bool, at: Moment, by: Initiator<L.Principal>,
            because: String, effects: [L.Effect], record: IdempotencyKey
        ) {
            var keys: [IdempotencyKey] = []
            keys.reserveCapacity(effects.count)
            for (position, effect) in effects.enumerated() {
                let key = IdempotencyKey.lifecycle(record: record, entry: sequence, position: position)
                keys.append(key)
                self.effects.append(LifecycleEffect(key: key, effect: effect, record: record, entry: sequence))
            }
            entries.append(LifecycleEntry(
                record: record, sequence: sequence, from: from, event: event, to: to, entered: entered, at: at,
                by: by, because: because, effects: keys))
            sequence += 1
            updated = at
            state = to
            if entered { since = at }
        }
    }

    /// Applies the timeouts due by `now`, in order, from the written state.
    func project(at now: Moment) -> Projection {
        var projection = Projection(state: state, since: since, updated: updated, sequence: sequence)
        var steps = 0
        while let timeout = L.timeout(in: projection.state) {
            let due = timeout.due(since: projection.since)
            guard due <= now else { break }
            guard steps < Self.timedStepLimit else {
                projection.truncated = true
                break
            }
            switch L.transition(from: projection.state, on: timeout.event) {
            case .to(let next, let effects):
                // Dated at the due moment, raised to the latest entry's: a
                // history's moments never go backwards, and an `.at` that had
                // passed when the state was entered is dated at the entry.
                projection.add(
                    from: projection.state, event: timeout.event, to: next, entered: true,
                    at: max(due, projection.updated), by: .timeout, because: timeout.reason, effects: effects,
                    record: key)
                steps += 1
            case .stay, .refuse, .ignore, .invalid:
                // A state whose own timeout does not move it: the read
                // stops here, and `StateGraph.stuckTimeouts` names it.
                projection.refusedTimeout = timeout.event
                return projection
            }
        }
        return projection
    }
}

extension IdempotencyKey {
    /// The key of effect number `position` of the history entry `entry` of
    /// the record whose key is `record`.
    ///
    /// Like design/22's derived keys, each half is a SplitMix64-finalised
    /// FNV-1a hash of the domain tag `lifecycle`, the half's index, one half
    /// of the record's key, the entry and the position, written as 16
    /// lowercase hexadecimal digits. So computing the same change twice, or
    /// committing the same due timeout from two places, gives the same keys,
    /// and they are as unpredictable as the record's random key.
    ///
    /// **Frozen.** A key outlives the process and the build that made it,
    /// and a receiver deduplicates by it: the function never changes.
    public static func lifecycle(record: IdempotencyKey, entry: UInt64, position: Int) -> IdempotencyKey {
        func half(_ part: Substring, _ which: UInt64) -> UInt64 {
            var hash = StableHash()
            hash.combine("lifecycle")
            hash.combine(which)
            hash.combine(part.utf8)
            hash.combine(CollectionOfOne(0xFF))
            hash.combine(entry)
            hash.combine(UInt64(truncatingIfNeeded: position))
            var z = hash.value &+ 0x9E37_79B9_7F4A_7C15
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        let raw = record.rawValue
        let middle = raw.index(raw.startIndex, offsetBy: raw.count / 2)
        return IdempotencyKey(rawValue: hexadecimal(half(raw[..<middle], 0)) + hexadecimal(half(raw[middle...], 1)))
    }

    private static func hexadecimal(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }
}
