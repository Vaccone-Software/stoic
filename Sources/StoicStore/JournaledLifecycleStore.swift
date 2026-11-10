public import Stoic

/// Lifecycle records kept durably on a device: heads and histories in a
/// ``Journal``, effects handed to an ``Outbox`` beside it.
///
///     let releases = try await JournaledLifecycleStore<ReleaseOnThisMac, String>.open(
///         at: support + "/releases", fileSystem: PosixFileSystem(newFileMode: 0o600, newDirectoryMode: 0o700))
///
///     try await releases.apply(.confirm, to: tag, by: .successor(pid: getpid()), because: "the router answered")
///
///     // At launch and on a timer: commit what has fallen due, then deliver what is owed.
///     try await releases.settleDue()
///     try await releases.deliverEffects { delivery in
///         await voice.say(delivery.effect, release: delivery.id)
///         return .delivered
///     }
///
/// **A commit is one journal append**: the new head, its history entries and
/// its effects' intents, framed and checksummed together. After a crash the
/// commit happened, with its effects inside it, or it did not; never a head
/// without its entries. The effects are then handed to the outbox (at
/// `path.effects`) under their keys, and delivered at least once. A hand-off
/// that fails does not undo the commit: it is retried, in order, before the
/// next commit, by ``settleDue(at:)``, by ``deliverEffects(using:)`` and at
/// open. The outbox remembers the keys of the last `rememberSettled` entries
/// to settle, so a hand-off repeated after a crash never sends an effect
/// that was already delivered.
///
/// **Time does not go backwards for its records.** The store never reads or
/// applies at a moment earlier than the latest one it has seen: every `now`
/// it was given and every entry's moment. It keeps that moment in memory
/// and makes it durable with each append and at ``close()``, and reports a
/// clamp (`lifecycle.clock_behind`). So a person who sets the device's clock
/// back cannot un-expire a state through this store. The limit: across a
/// relaunch with no append since the last read, a clock set back can still
/// un-do a projected, uncommitted expiry. ``settleDue(at:)`` at launch, and
/// on a schedule, turns a due transition into a fact; a deadline that must
/// hold against the device's owner belongs to a server.
///
/// **A record this build cannot decode** (a state a newer build added) is
/// kept as its bytes, listed in ``openReport``, refused by ``load(_:)`` and
/// ``commit(_:to:)`` with `.corrupt`, and never overwritten: it goes back to
/// the newer build intact.
///
/// It is not a database: every record and its history are held in memory
/// and the log is read whole at open. A thousand records with long
/// histories belong in a database, through a `LifecycleStore` of its own.
public actor JournaledLifecycleStore<L: Lifecycle, ID: Hashable & Sendable & Codable>: LifecycleStore {
    public typealias Definition = L
    public typealias Failure = StoreError

    /// What opening found.
    public nonisolated let openReport: LifecycleOpenReport<ID>

    private let path: String
    private let journal: Journal
    /// The effects' outbox; internal, so the crash tests can read it.
    let outbox: Outbox<LifecycleDelivery<L, ID>>
    /// A defect the crash tests build in on purpose, to prove the harness
    /// catches it; `nil` everywhere else.
    private let defect: Defect?

    /// The ways a store could get its commit wrong, which the crash tests
    /// must catch.
    enum Defect: Sendable {
        /// Hands effects to the outbox before the commit is appended.
        case enqueueBeforeAppend
        /// Appends the head and its entries as two records.
        case headAndEntriesApart
        /// Opens the outbox without remembering settled keys.
        case forgetSettled
    }
    private let compactionThreshold: Int
    private var state: Contents
    /// Callers waiting for the hand-off in progress to finish.
    private var handOffWaiters: [CheckedContinuation<Void, Never>] = []
    private var handingOff = false

    /// Everything the journal holds, decoded where this build can.
    struct Contents {
        var slots: [ID: Slot] = [:]
        /// Ids in the order they were inserted.
        var order: [ID] = []
        /// Commits whose effects are not yet known to be in the outbox, in
        /// commit order.
        var handOff: [(sequence: UInt64, effects: [LifecycleStoreFormat.Effect])] = []
        /// The latest moment seen, and the one last made durable.
        var seen = Moment.epoch
        var durableSeen = Moment.epoch
        var durableHandedOff: UInt64 = 0
    }

    enum Slot {
        case kept(L.Record, [L.Entry])
        /// Documents this build cannot decode, kept as they were written.
        case undecodable(id: [UInt8], head: [UInt8], entries: [[UInt8]])
    }

    private init(
        path: String, journal: Journal, outbox: Outbox<LifecycleDelivery<L, ID>>, compactionThreshold: Int, state: Contents,
        openReport: LifecycleOpenReport<ID>, defect: Defect?
    ) {
        self.defect = defect
        self.path = path
        self.journal = journal
        self.outbox = outbox
        self.compactionThreshold = compactionThreshold
        self.state = state
        self.openReport = openReport
    }

    // MARK: Opening

    /// Opens the store at `path` (a journal there, its outbox at
    /// `path.effects`), recovers what the last run left, and hands to the
    /// outbox the effects of every commit it had not yet handed over
    /// (`lifecycle.handoff_resumed`).
    ///
    /// - Parameters:
    ///   - path: Where the journal is kept; its snapshot and the outbox's
    ///     files sit beside it.
    ///   - fileSystem: The file system the files are on.
    ///   - delivery: How the outbox delivers effects.
    ///   - rememberSettled: How many settled effect keys the outbox
    ///     remembers, so a repeated hand-off sends nothing twice (design/27,
    ///     the bound).
    ///   - compactionThreshold: Once the log passes this many bytes, and
    ///     every commit is handed off, heads and histories are folded into a
    ///     snapshot.
    ///   - journalOptions: How both journals are opened.
    public static func open(
        at path: String,
        fileSystem: any FileSystem = PosixFileSystem(),
        delivery: DeliveryPolicy = DeliveryPolicy(),
        rememberSettled: Int = 4_096,
        compactionThreshold: Int = 256 * 1024,
        journalOptions: Journal.Options = Journal.Options()
    ) async throws(StoreError) -> JournaledLifecycleStore {
        try await open(
            at: path, fileSystem: fileSystem, delivery: delivery, rememberSettled: rememberSettled,
            compactionThreshold: compactionThreshold, journalOptions: journalOptions, defect: nil)
    }

    /// ``open(at:fileSystem:delivery:rememberSettled:compactionThreshold:journalOptions:)``
    /// with a defect built in, for the crash tests that must fail.
    static func open(
        at path: String, fileSystem: any FileSystem, delivery: DeliveryPolicy, rememberSettled: Int,
        compactionThreshold: Int, journalOptions: Journal.Options, defect: Defect?
    ) async throws(StoreError) -> JournaledLifecycleStore {
        guard rememberSettled > 0 else {
            throw StoreError(
                kind: .invalidArgument, operation: "open", path: path,
                detail: "rememberSettled must be at least 1: a repeated hand-off would send effects twice")
        }
        let journal = try Journal.open(at: path, fileSystem: fileSystem, options: journalOptions)
        let outbox: Outbox<LifecycleDelivery<L, ID>>
        let state: Contents
        let undecodable: [ID]
        do throws(StoreError) {
            (state, undecodable) = try recover(journal.replay(), path: path)
            outbox = try Outbox.open(
                at: path + ".effects", codec: .json(), fileSystem: fileSystem, policy: delivery,
                journalOptions: journalOptions, rememberSettled: defect == .forgetSettled ? 0 : rememberSettled)
        } catch {
            do throws(StoreError) { try journal.close() } catch {}
            throw error
        }
        let report = LifecycleOpenReport(
            journal: journal.openReport, effects: outbox.openReport, undecodable: undecodable,
            handOffsResumed: state.handOff.count)
        let store = JournaledLifecycleStore(
            path: path, journal: journal, outbox: outbox, compactionThreshold: compactionThreshold, state: state,
            openReport: report, defect: defect)
        for _ in undecodable {
            StoreEvents.record(Event("lifecycle.undecodable", level: .error, label: L.name, fields: [
                .init("path", .string(path)),
            ]))
        }
        if !state.handOff.isEmpty {
            StoreEvents.record(Event("lifecycle.handoff_resumed", level: .notice, label: L.name, fields: [
                .init("commits", .int(state.handOff.count)),
            ]))
            await store.handOff()
        }
        return store
    }

    /// The store's contents, rebuilt from the snapshot and the log.
    private static func recover(_ replay: Journal.Replay, path: String) throws(StoreError) -> (Contents, [ID]) {
        var state = Contents()
        var handedOff: UInt64 = 0
        if let snapshot = replay.snapshot {
            let saved = try LifecycleStoreFormat.snapshot(snapshot.bytes, path: path)
            handedOff = saved.handedOff
            state.seen = saved.seen
            for record in saved.records {
                let id = try decodeID(record.id, path: path)
                state.order.append(id)
                state.slots[id] = slot(id: record.id, head: record.head, entries: record.entries)
            }
        }
        for stored in replay.records {
            let record = try LifecycleStoreFormat.record(stored.bytes, path: path)
            handedOff = max(handedOff, record.handedOff)
            state.seen = max(state.seen, record.seen)
            switch record.kind {
            case .insert:
                let id = try decodeID(record.documents[0], path: path)
                if state.slots[id] == nil { state.order.append(id) }
                state.slots[id] = slot(id: record.documents[0], head: record.documents[1], entries: [])
            case .commit:
                let id = try decodeID(record.documents[0], path: path)
                if state.slots[id] == nil { state.order.append(id) }
                state.slots[id] = following(
                    state.slots[id], id: record.documents[0], head: record.documents[1], entries: record.entries)
                if !record.effects.isEmpty { state.handOff.append((stored.sequence, record.effects)) }
            case .purge:
                let ids = try record.documents.map { (document) throws(StoreError) in try decodeID(document, path: path) }
                let purged = Set(ids)
                for id in ids { state.slots[id] = nil }
                state.order.removeAll { purged.contains($0) }
            case .mark:
                break
            }
        }
        // A commit at or before the durable mark had its effects handed over.
        state.handOff.removeAll { $0.sequence <= handedOff }
        state.durableHandedOff = handedOff
        for id in state.order {
            if case .kept(let record, _) = state.slots[id] { state.seen = max(state.seen, record.written.updated) }
        }
        state.durableSeen = state.seen
        let undecodable = state.order.filter { if case .undecodable = state.slots[$0] { true } else { false } }
        return (state, undecodable)
    }

    private static func decodeID(_ bytes: [UInt8], path: String) throws(StoreError) -> ID {
        guard let id = LifecycleStoreFormat.decode(ID.self, from: bytes) else {
            throw StoreError(kind: .corrupt, operation: "lifecycle", path: path, detail: "an id does not decode")
        }
        return id
    }

    /// A record from its documents: decoded, or kept as bytes if any part
    /// does not decode.
    private static func slot(id: [UInt8], head: [UInt8], entries: [[UInt8]]) -> Slot {
        guard let record = LifecycleStoreFormat.decode(L.Record.self, from: head) else {
            return .undecodable(id: id, head: head, entries: entries)
        }
        var history: [L.Entry] = []
        history.reserveCapacity(entries.count)
        for entry in entries {
            guard let decoded = LifecycleStoreFormat.decode(L.Entry.self, from: entry) else {
                return .undecodable(id: id, head: head, entries: entries)
            }
            history.append(decoded)
        }
        return .kept(record, history)
    }

    /// The record after a commit's documents: decoded if it and everything
    /// before it decode, else all of it kept as bytes.
    private static func following(_ slot: Slot?, id: [UInt8], head: [UInt8], entries: [[UInt8]]) -> Slot {
        switch slot {
        case .kept(_, let history):
            if case .kept(let record, let added) = Self.slot(id: id, head: head, entries: entries) {
                return .kept(record, history + added)
            }
            // The history this build decoded, written back as it was decoded,
            // ahead of what it cannot read.
            let earlier = history.compactMap { entry -> [UInt8]? in
                do throws(StoreError) { return try LifecycleStoreFormat.encode(entry, "an entry") } catch { return nil }
            }
            return .undecodable(id: id, head: head, entries: earlier + entries)
        case .undecodable(_, _, let earlier):
            return .undecodable(id: id, head: head, entries: earlier + entries)
        case nil:
            // A commit whose insert the log lost: kept, never guessed at.
            return .undecodable(id: id, head: head, entries: entries)
        }
    }

    // MARK: LifecycleStore

    public func load(_ id: ID) throws(StoreError) -> L.Record? {
        switch state.slots[id] {
        case .kept(let record, _): record
        case .undecodable: throw undecodable(id, "load")
        case nil: nil
        }
    }

    public func history(of id: ID) throws(StoreError) -> [L.Entry] {
        switch state.slots[id] {
        case .kept(_, let history): history
        case .undecodable: throw undecodable(id, "history")
        case nil: []
        }
    }

    public func insert(_ record: L.Record, as id: ID) throws(StoreError) -> Bool {
        guard state.slots[id] == nil else { return false }
        let idBytes = try LifecycleStoreFormat.encode(id, "an id")
        let head = try LifecycleStoreFormat.encode(record, "a record")
        let seen = max(state.seen, record.written.updated)
        let mark = handedOffMark
        try journal.append(LifecycleStoreFormat.insert(id: idBytes, head: head, handedOff: mark, seen: seen))
        noteDurable(seen: seen, handedOff: mark)
        state.slots[id] = .kept(record, [])
        state.order.append(id)
        compactIfNeeded()
        return true
    }

    /// Commits `change` as one journal append, then hands its effects to
    /// the outbox. Returns `LifecycleCommit.committed` once the append is
    /// durable, whatever the hand-off does (`lifecycle.handoff_deferred`).
    ///
    /// - Throws: `.corrupt` for a record this build cannot decode;
    ///   `.invalidArgument` for a change made from another record, or one
    ///   that does not follow the stored record; the journal's error if the
    ///   append fails, in which case nothing changed.
    public func commit(_ change: L.Change, to id: ID) async throws(StoreError) -> LifecycleCommit<L> {
        // Hand-offs go in commit order: an earlier one still owed goes first.
        await handOff()
        if defect == .enqueueBeforeAppend {
            for effect in change.effects {
                let delivery = try LifecycleStoreFormat.encode(
                    LifecycleDelivery<L, ID>(id: id, key: effect.key, effect: effect.effect), "an effect")
                try await outbox.enqueue(encoded: delivery, key: effect.key)
            }
        }
        let outcome = try commitNow(change, to: id)
        if case .committed = outcome {
            await handOff()
            compactIfNeeded()
        }
        return outcome
    }

    /// The store's moment for `now`: `now`, or the latest moment the store
    /// has seen if `now` is earlier (`lifecycle.clock_behind`).
    public func moment(for now: Moment) async -> Moment {
        clamped(now)
    }

    private func clamped(_ now: Moment) -> Moment {
        guard now >= state.seen else {
            LifecycleEvents.clockBehind(L.self, by: now.duration(to: state.seen))
            return state.seen
        }
        state.seen = now
        return now
    }

    private func commitNow(_ change: L.Change, to id: ID) throws(StoreError) -> LifecycleCommit<L> {
        let current: L.Record
        switch state.slots[id] {
        case .kept(let record, _): current = record
        case .undecodable: throw undecodable(id, "commit")
        case nil: return .conflict(current: nil)
        }
        guard current.key == change.record.key else {
            throw StoreError(
                kind: .invalidArgument, operation: "commit", path: path, detail: "the change was made from another record")
        }
        guard current.revision == change.base else { return .conflict(current: current) }
        guard change.follows(current) else {
            throw StoreError(
                kind: .invalidArgument, operation: "commit", path: path, detail: "the change does not follow the stored record")
        }
        let effects = try change.effects.map { (effect) throws(StoreError) in
            LifecycleStoreFormat.Effect(
                key: effect.key,
                delivery: try LifecycleStoreFormat.encode(
                    LifecycleDelivery<L, ID>(id: id, key: effect.key, effect: effect.effect), "an effect"))
        }
        let seen = [change.at, change.record.written.updated].reduce(state.seen, max)
        let mark = handedOffMark
        let payload = LifecycleStoreFormat.commit(
            id: try LifecycleStoreFormat.encode(id, "an id"), head: try LifecycleStoreFormat.encode(change.record, "a record"),
            entries: try change.entries.map { (entry) throws(StoreError) in try LifecycleStoreFormat.encode(entry, "an entry") },
            effects: effects, handedOff: mark, seen: seen)
        let sequence: UInt64
        if defect == .headAndEntriesApart {
            try journal.append(LifecycleStoreFormat.commit(
                id: try LifecycleStoreFormat.encode(id, "an id"), head: try LifecycleStoreFormat.encode(change.record, "a record"),
                entries: [], effects: effects, handedOff: mark, seen: seen))
            sequence = try journal.append(LifecycleStoreFormat.commit(
                id: try LifecycleStoreFormat.encode(id, "an id"), head: try LifecycleStoreFormat.encode(change.record, "a record"),
                entries: try change.entries.map { (entry) throws(StoreError) in try LifecycleStoreFormat.encode(entry, "an entry") },
                effects: [], handedOff: mark, seen: seen))
        } else {
            sequence = try journal.append(payload)
        }
        // Committed from here on, whatever follows.
        noteDurable(seen: seen, handedOff: mark)
        if case .kept(_, let history) = state.slots[id] {
            state.slots[id] = .kept(change.record, history + change.entries)
        }
        if !effects.isEmpty { state.handOff.append((sequence, effects)) }
        return .committed
    }

    // MARK: Reading the store

    /// Every record this build can decode, in the order they were inserted.
    public func records() -> [(id: ID, record: L.Record)] {
        state.order.compactMap { id in
            if case .kept(let record, _) = state.slots[id] { return (id, record) }
            return nil
        }
    }

    /// The earliest moment a record's timeout falls due, of the records
    /// ``settleDue(at:)`` can settle: when to call it again. A record whose
    /// definition cannot settle it (its timeout does not move it, its chain
    /// is cut, a newer definition wrote it) is left out, so a caller that
    /// waits for this never spins on it.
    public var nextDue: Moment? {
        var earliest: Moment?
        for id in state.order {
            guard case .kept(let record, _) = state.slots[id], let due = record.written.dueAt else { continue }
            if let earliest, earliest <= due { continue }
            guard Self.canSettle(record, at: max(due, state.seen)) else { continue }
            earliest = due
        }
        return earliest
    }

    private static func canSettle(_ record: L.Record, at now: Moment) -> Bool {
        do throws(L.Refusal) {
            return try record.settling(at: now) != nil
        } catch {
            return false
        }
    }

    // MARK: Settling

    /// Commits every timeout due at the store's moment for `now`: the
    /// settling change of every record whose `LifecycleRecord.Written.dueAt`
    /// is not after it, as **one batch append** (every record settled, or
    /// none), then hands their effects to the outbox.
    ///
    /// A record the definition cannot settle is left as it is and reported
    /// (`lifecycle.timeout_refused`, `lifecycle.chain_truncated`,
    /// `lifecycle.newer_definition`).
    ///
    /// - Returns: How many records were settled.
    /// - Throws: The journal's error if the append fails; then nothing was
    ///   settled.
    @discardableResult
    public func settleDue(at now: Moment = .now) async throws(StoreError) -> Int {
        await handOff()
        let now = clamped(now)
        var changes: [(id: ID, change: L.Change)] = []
        for id in state.order {
            guard case .kept(let record, _) = state.slots[id], let due = record.written.dueAt, due <= now else { continue }
            do throws(L.Refusal) {
                if let change = try record.settling(at: now) {
                    changes.append((id, change))
                } else if let event = record.read(at: now).refusedTimeout {
                    LifecycleEvents.timeoutRefused(L.self, state: record.written.state, event: event)
                }
            } catch {
                LifecycleEvents.refused(error)
            }
        }
        guard !changes.isEmpty else { return 0 }
        let idBytes = try changes.map { (item) throws(StoreError) in try LifecycleStoreFormat.encode(item.id, "an id") }
        var effects: [[LifecycleStoreFormat.Effect]] = []
        var payloads: [[UInt8]] = []
        let seen = changes.map(\.change.record.written.updated).reduce(max(state.seen, now), max)
        let mark = handedOffMark
        for (index, item) in changes.enumerated() {
            let owed = try item.change.effects.map { (effect) throws(StoreError) in
                LifecycleStoreFormat.Effect(
                    key: effect.key,
                    delivery: try LifecycleStoreFormat.encode(
                        LifecycleDelivery<L, ID>(id: item.id, key: effect.key, effect: effect.effect), "an effect"))
            }
            effects.append(owed)
            payloads.append(LifecycleStoreFormat.commit(
                id: idBytes[index], head: try LifecycleStoreFormat.encode(item.change.record, "a record"),
                entries: try item.change.entries.map { (entry) throws(StoreError) in try LifecycleStoreFormat.encode(entry, "an entry") },
                effects: owed, handedOff: mark, seen: seen))
        }
        let sequences = try journal.append(batch: payloads)
        noteDurable(seen: seen, handedOff: mark)
        for (index, item) in changes.enumerated() {
            if case .kept(_, let history) = state.slots[item.id] {
                state.slots[item.id] = .kept(item.change.record, history + item.change.entries)
            }
            if !effects[index].isEmpty { state.handOff.append((sequences[index], effects[index])) }
            LifecycleEvents.committed(item.change)
        }
        await handOff()
        compactIfNeeded()
        return changes.count
    }

    // MARK: Effects

    /// Hands every owed effect to the outbox, then delivers what is pending
    /// there, in order, at least once, each under its key: the outbox's
    /// `deliverPending(using:)`, with its rules for results, retries and
    /// cancellation (the entry in flight stays pending).
    ///
    /// Commits go on while a delivery waits on the network: the outbox is
    /// its own actor, and this one is free while it waits. `deliver` is
    /// `@Sendable` because it is handed to the outbox's actor.
    public func deliverEffects(
        using deliver: @Sendable (LifecycleDelivery<L, ID>) async throws -> DeliveryResult
    ) async throws -> Outbox<LifecycleDelivery<L, ID>>.DeliveryReport {
        await handOff()
        return try await outbox.deliverPending { entry in try await deliver(entry.item) }
    }

    /// The journal sequence up to which every commit's effects are in the
    /// outbox: written into each append, and so made durable with it.
    private var handedOffMark: UInt64 {
        state.handOff.first.map { $0.sequence - 1 } ?? journal.lastSequence
    }

    /// Hands owed effects to the outbox, in commit order, until none is
    /// owed or one fails (`lifecycle.handoff_deferred`). One hand-off runs
    /// at a time; a caller that finds one running waits for it to finish.
    func handOff() async {
        if handingOff {
            await withCheckedContinuation { handOffWaiters.append($0) }
            return
        }
        handingOff = true
        defer {
            handingOff = false
            let waiters = handOffWaiters
            handOffWaiters = []
            for waiter in waiters { waiter.resume() }
        }
        while let next = state.handOff.first {
            for effect in next.effects {
                do throws(StoreError) {
                    try await outbox.enqueue(encoded: effect.delivery, key: effect.key)
                } catch {
                    StoreEvents.record(Event("lifecycle.handoff_deferred", level: .warning, label: L.name, fields: [
                        .init("error", .error(error)),
                        .init("owed", .int(state.handOff.count)),
                    ]))
                    return
                }
            }
            state.handOff.removeFirst()
        }
    }

    // MARK: Maintenance

    /// Removes every record that is final as read at the store's moment for
    /// now, whose final state was entered before `finishedBefore`, with its
    /// history, as one journal record (`lifecycle.purged`). A record that is
    /// not final as read now is never purged, nor one this build cannot
    /// decode.
    ///
    /// - Returns: How many records were removed.
    @discardableResult
    public func purge(finishedBefore: Moment) throws(StoreError) -> Int {
        let now = clamped(.now)
        let ids = state.order.filter { id in
            guard case .kept(let record, _) = state.slots[id] else { return false }
            let reading = record.read(at: now)
            return reading.isFinal && reading.since < finishedBefore
        }
        guard !ids.isEmpty else { return 0 }
        let documents = try ids.map { (id) throws(StoreError) in try LifecycleStoreFormat.encode(id, "an id") }
        let mark = handedOffMark
        try journal.append(LifecycleStoreFormat.purge(ids: documents, handedOff: mark, seen: state.seen))
        noteDurable(seen: state.seen, handedOff: mark)
        let purged = Set(ids)
        for id in ids { state.slots[id] = nil }
        state.order.removeAll { purged.contains($0) }
        StoreEvents.record(Event("lifecycle.purged", level: .info, label: L.name, fields: [.init("count", .int(ids.count))]))
        compactIfNeeded()
        return ids.count
    }

    /// Makes the latest moment seen durable, if it moved since the last
    /// append, and stops using the files. Further calls throw.
    public func close() async throws(StoreError) {
        let mark = handedOffMark
        if state.seen > state.durableSeen || mark > state.durableHandedOff {
            try journal.append(LifecycleStoreFormat.mark(handedOff: mark, seen: state.seen))
            noteDurable(seen: state.seen, handedOff: mark)
        }
        try journal.close()
        try await outbox.close()
    }

    /// Deletes a closed store's files: the journal's and the outbox's.
    ///
    /// - Returns: How many files were removed.
    public static func remove(at path: String, fileSystem: any FileSystem = PosixFileSystem()) throws(StoreError) -> Int {
        try Journal.remove(at: path, fileSystem: fileSystem) + Journal.remove(at: path + ".effects", fileSystem: fileSystem)
    }

    /// Notes what an append that just became durable carried.
    private func noteDurable(seen: Moment, handedOff: UInt64) {
        state.seen = max(state.seen, seen)
        state.durableSeen = max(state.durableSeen, seen)
        state.durableHandedOff = max(state.durableHandedOff, handedOff)
    }

    /// Folds heads and histories into a snapshot once the log is long and
    /// nothing is owed to the outbox, so the snapshot never carries effects.
    /// A failure loses nothing (the log is still whole): reported, not
    /// thrown.
    private func compactIfNeeded() {
        guard journal.byteCount > compactionThreshold, state.handOff.isEmpty else { return }
        do throws(StoreError) {
            var snapshot = LifecycleStoreFormat.Snapshot(handedOff: journal.lastSequence, seen: state.seen)
            for id in state.order {
                switch state.slots[id] {
                case .kept(let record, let history):
                    snapshot.records.append((
                        try LifecycleStoreFormat.encode(id, "an id"), try LifecycleStoreFormat.encode(record, "a record"),
                        try history.map { (entry) throws(StoreError) in try LifecycleStoreFormat.encode(entry, "an entry") }
                    ))
                case .undecodable(let id, let head, let entries):
                    snapshot.records.append((id, head, entries))
                case nil:
                    continue
                }
            }
            let bytes = LifecycleStoreFormat.snapshot(snapshot)
            try journal.compact(snapshot: bytes)
            noteDurable(seen: state.seen, handedOff: snapshot.handedOff)
        } catch {
            StoreEvents.record(Event("lifecycle.maintenance_failed", level: .warning, label: L.name, fields: [
                .init("operation", .string("compact"), privacy: .public), .init("error", .error(error)),
            ]))
        }
    }

    private func undecodable(_ id: ID, _ operation: String) -> StoreError {
        StoreError(
            kind: .corrupt, operation: operation, path: path,
            detail: "the record does not decode: written by a newer build, or damaged; it is kept as it was")
    }
}

/// One effect owed, as the outbox delivers it: the record's id, the key to
/// send, and the effect.
public struct LifecycleDelivery<L: Lifecycle, ID: Hashable & Sendable & Codable>: Sendable, Codable {
    /// The id of the record whose transition owes it.
    public let id: ID
    /// Derived from the record, the entry and the effect's place in it:
    /// send it to the receiver, which then acts once.
    public let key: IdempotencyKey
    public let effect: L.Effect
}

/// What opening a ``JournaledLifecycleStore`` found.
public struct LifecycleOpenReport<ID: Hashable & Sendable>: Sendable {
    /// The journal of heads and histories.
    public let journal: Journal.OpenReport
    /// The outbox of effects.
    public let effects: Journal.OpenReport
    /// Records this build cannot decode, kept as they were: written by a
    /// newer build, or damaged.
    public let undecodable: [ID]
    /// How many commits had effects not yet in the outbox, and were handed
    /// over again.
    public let handOffsResumed: Int
}
