public import Stoic
internal import Synchronization

/// Durable at-least-once delivery of operations, built on a ``Journal``.
///
/// The transactional-outbox pattern: instead of calling the server and hoping,
/// the app writes "send this" to disk (`enqueue`, durable before it returns)
/// and a delivery loop sends what is pending, acknowledging each entry only
/// after the server accepted it. A crash, a kill, a flat battery or a week
/// offline loses nothing; the next launch resumes where the last one stopped.
///
///     let outbox = try Outbox<Message>.open(at: dir + "/outbox", codec: .json())
///
///     // When the user taps Send, a crash a microsecond later cannot lose it:
///     let key = try await outbox.enqueue(Message(text: "hello"))
///
///     // At launch, on reconnect, on a timer:
///     let report = try await outbox.deliverPending { entry in
///         try await server.send(entry.item, idempotencyKey: entry.key)
///         return .delivered
///     }
///
/// Over `HTTPClient`, with the client making one attempt and the outbox doing
/// the retrying across runs and launches, and a refusal that will never
/// succeed leaving the queue instead of blocking it:
///
///     let api = HTTPClient(base: url, policy: .singleAttempt)
///     let outbox = try Outbox<Note>.open(
///         at: dir + "/outbox", codec: .json(),
///         fileSystem: PosixFileSystem(newFileMode: 0o600, newDirectoryMode: 0o700))   // private
///
///     // Send now, and learn what became of this one note; a timer drains the rest.
///     let key = try await outbox.enqueue(note)
///     let outcome = try await outbox.deliver(key) { entry in
///         do {
///             _ = try await api.send(entry.item.request, idempotencyKey: entry.key)
///             return .delivered
///         } catch HTTPError.status(let code, _, _, _, _) where code == 400 || code == 422 {
///             return .discard(reason: "http \(code)")
///         }
///     }
///
/// ## Semantics: at least once
///
/// - **No acknowledged entry is lost.** Once `enqueue` returns the entry is
///   pending until a delivery of it succeeds *and its acknowledgement is
///   durable*.
/// - **An entry may be delivered more than once.** If the app dies after the
///   server accepted an entry but before the acknowledgement reached the
///   disk, the next launch delivers it again. This cannot be closed from the
///   client side. The defence is the **idempotency key**: each entry gets one
///   `IdempotencyKey` at enqueue, the same key goes with every attempt of
///   every launch, and a server that honours it makes the repeat harmless.
///   An entry delivered to a server that does not deduplicate must be an
///   operation that is safe to repeat.
/// - **Order.** Entries are delivered in enqueue order. By default a failing
///   entry stops the run (so later entries cannot overtake it); see
///   ``DeliveryPolicy/FailureMode``. ``deliver(_:using:)`` is the one
///   exception: it delivers the entry you name, whatever is ahead of it.
/// - **Retry.** Each attempt sequence runs under Stoic's `retry` with the
///   policy's bounded schedule and classifier, so a `Retryable` error that
///   says `.stop` (a 4xx, say) is not retried. When the schedule is spent the
///   entry stays pending for the next run; nothing is dropped. A declared
///   operation's `perform` inside `deliver` that gives up settles the
///   attempt, which is then not repeated in this run (design/22).
/// - **A delivery says what became of its entry.** The closure returns a
///   ``DeliveryResult``: `.delivered` (acknowledge), `.discard(reason:)` (the
///   server refused it for good: acknowledge, so it leaves the queue, and
///   report it as discarded, not delivered) or `.keep` (not delivered, not an
///   error; pending, and not tried again in this run). *Throwing* leaves the
///   entry pending whatever the error's `retryDecision`: a `.stop` means "do
///   not retry in this run", and the same 401, 403 or full disk is permanent
///   for the run and transient for the day, so only the app can say which
///   refusals are permanent, and it says so with a value, not by what it throws.
/// - **Entries that cannot be sent.** An entry that no longer decodes, or is
///   older than ``DeliveryPolicy/Expiry/maxAge``, is handled by the policy
///   (``DeliveryPolicy/onUndecodable``, ``DeliveryPolicy/expiry``) and reported,
///   so it does not hold the queue forever.
/// - **Keys inside.** The entry's key is the enclosing key of every attempt:
///   a `.keyed` operation performed inside `deliver` without a key of its own
///   derives one from it, the same on every attempt and every relaunch.
///
///       try await outbox.deliverPending { entry in
///           try await Payments.subscribe.perform { attempt in
///               try await api.subscribe(entry.item, idempotencyKey: attempt.idempotencyKey)
///           }
///           return .delivered
///       }
/// - **One delivery at a time.** Never two attempts of one entry, and never
///   two runs: a `deliverPending(using:)` that starts while another delivery
///   is going returns at once (``DeliveryReport/wasAlreadyRunning``), and a
///   ``deliver(_:using:)`` waits its turn.
/// - **Cancellation.** Cancelling `deliverPending` stops it at once; the
///   entry in flight stays pending.
///
/// Items are stored as bytes by an ``OutboxCodec``. One `Outbox` per path per
/// process.
public actor Outbox<Item: Sendable> {
    /// One pending operation.
    public struct Entry: Sendable {
        /// The key to send with every attempt, assigned (or supplied) at enqueue.
        public let key: IdempotencyKey
        public let item: Item
        /// The entry's position in the journal; increases in enqueue order.
        public let sequence: UInt64
    }

    /// What a delivery run did.
    public struct DeliveryReport: Sendable {
        public struct Failure: Sendable {
            public let key: IdempotencyKey
            /// The last attempt's error.
            public let error: any Error
            /// How many attempts the entry got in this run.
            public let attempts: Int
        }

        /// An entry dropped from the queue without being delivered.
        public struct Discard: Sendable {
            public let key: IdempotencyKey
            public let reason: DiscardReason
            /// How many attempts the entry got in this run: none for an entry
            /// that was undecodable or expired, and so never sent.
            public let attempts: Int
        }

        /// Entries delivered and acknowledged, in order.
        public var delivered: [IdempotencyKey] = []
        /// Entries dropped from the queue without being delivered, in order:
        /// refused for good by the delivery (``DeliveryResult/discard(reason:)``),
        /// undecodable (``DeliveryPolicy/onUndecodable``) or expired
        /// (``DeliveryPolicy/expiry``). Each is acknowledged durably, so it is
        /// not delivered again, and not counted in ``delivered``.
        public var discarded: [Discard] = []
        /// Entries that exhausted their attempts (or failed permanently) in this run.
        public var failed: [Failure] = []
        /// Entries whose delivery returned ``DeliveryResult/keep``: still
        /// pending, no error to report.
        public var kept: [IdempotencyKey] = []
        /// How many entries are still pending afterwards.
        public var remaining = 0
        /// `true` if another delivery was already running; this call did nothing.
        public var wasAlreadyRunning = false
    }

    private struct Stored {
        let key: IdempotencyKey
        let sequence: UInt64
        let bytes: [UInt8]
        /// Wall-clock milliseconds since 1970 at enqueue; `nil` for an entry
        /// enqueued with no ``DeliveryPolicy/expiry`` (it never expires).
        let enqueuedAt: Int64?
    }

    /// The pending entries in enqueue order, found by key in constant time.
    ///
    /// An array searched by key for every record made opening quadratic: a
    /// journal of 20,000 pending entries took 17 seconds. Removal leaves a
    /// hole that is skipped, and the holes are squeezed out once they
    /// outnumber the entries, so every operation is amortised constant time
    /// and the order never changes.
    private struct PendingQueue {
        private var slots: [Stored?] = []
        private var positions: [IdempotencyKey: Int] = [:]

        init() {}

        var count: Int { positions.count }

        func contains(_ key: IdempotencyKey) -> Bool { positions[key] != nil }

        func stored(for key: IdempotencyKey) -> Stored? { positions[key].flatMap { slots[$0] } }

        /// Adds an entry at the end; does nothing if its key is already pending.
        mutating func append(_ stored: Stored) {
            guard positions[stored.key] == nil else { return }
            positions[stored.key] = slots.count
            slots.append(stored)
        }

        mutating func remove(_ key: IdempotencyKey) {
            guard let position = positions.removeValue(forKey: key) else { return }
            slots[position] = nil
            if slots.count > 32, slots.count > 2 * positions.count { squeeze() }
        }

        /// The entries, in order.
        var entries: [Stored] { slots.compactMap { $0 } }

        private mutating func squeeze() {
            let live = entries
            slots = live.map { Optional($0) }
            positions.removeAll(keepingCapacity: true)
            for (position, stored) in live.enumerated() { positions[stored.key] = position }
        }
    }

    /// What opening the journal found: damage skipped in the middle of the
    /// log (each lost record is an enqueue never delivered or an
    /// acknowledgement whose entry is delivered again; the report says how
    /// many, not which), a torn tail cut, a lost snapshot accepted.
    public nonisolated let openReport: Journal.OpenReport

    private let journal: Journal
    private let codec: OutboxCodec<Item>
    private let policy: DeliveryPolicy
    private let compactionThreshold: Int
    private var pending: PendingQueue

    /// Who may deliver: one at a time, so an entry is never attempted twice at
    /// once and a run is never interleaved with another. A `Mutex` rather than
    /// actor state so that a waiter's cancellation, which arrives on any
    /// thread, can take it out of the queue at once.
    private let turn = Mutex(Turn())

    /// Callers of ``deliver(_:using:)`` waiting for the outcome of one entry,
    /// by watcher id: whatever attempt of that entry ends next (a run's, or
    /// the watcher's own) is its answer.
    private var watchers: [UInt64: Watcher] = [:]
    private var nextWatcher: UInt64 = 0

    private struct Watcher {
        let key: IdempotencyKey
        var outcome: DeliveryOutcome?
    }

    private struct Turn {
        var held = false
        var nextID: UInt64 = 0
        var queue: [(id: UInt64, continuation: CheckedContinuation<Void, any Error>)] = []
    }

    private init(journal: Journal, codec: OutboxCodec<Item>, policy: DeliveryPolicy, compactionThreshold: Int, pending: PendingQueue) {
        self.openReport = journal.openReport
        self.journal = journal
        self.codec = codec
        self.policy = policy
        self.compactionThreshold = compactionThreshold
        self.pending = pending
    }

    /// Opens the outbox at `path` (a journal and its snapshot beside it),
    /// recovering whatever was pending when the app last stopped.
    ///
    /// - Parameters:
    ///   - path: Where the journal is kept; its snapshot sits beside it.
    ///   - codec: How an entry becomes bytes and back.
    ///   - fileSystem: The file system the outbox's files are on.
    ///   - policy: How delivery is attempted, and when an entry is given up on.
    ///   - compactionThreshold: Once the log passes this many bytes after a
    ///     delivery run, the pending entries are folded into a snapshot and
    ///     the log truncated, so acknowledgements do not accumulate.
    ///   - journalOptions: How the journal underneath is opened. Set
    ///     ``Journal/Options/crossProcessLock`` when two processes share the
    ///     outbox (an app and its extension in an app group): without it each
    ///     keeps its own idea of where the log ends and they overwrite each
    ///     other's records. ``Journal/Options/lostSnapshot`` decides what a lost
    ///     snapshot does (``openReport`` says when one was accepted).
    public static func open(
        at path: String,
        codec: OutboxCodec<Item>,
        fileSystem: any FileSystem = PosixFileSystem(),
        policy: DeliveryPolicy = DeliveryPolicy(),
        compactionThreshold: Int = 64 * 1024,
        journalOptions: Journal.Options = Journal.Options()
    ) throws(StoreError) -> Outbox {
        let journal = try Journal.open(at: path, fileSystem: fileSystem, options: journalOptions)
        return try recover(journal, path: path, codec: codec, policy: policy, compactionThreshold: compactionThreshold)
    }

    /// ``open(at:codec:fileSystem:policy:compactionThreshold:journalOptions:)``,
    /// waiting up to `lockTimeout` for another process to let go of the
    /// outbox's lock (``Journal/Options/crossProcessLock``).
    public static func open(
        at path: String,
        codec: OutboxCodec<Item>,
        fileSystem: any FileSystem = PosixFileSystem(),
        policy: DeliveryPolicy = DeliveryPolicy(),
        compactionThreshold: Int = 64 * 1024,
        journalOptions: Journal.Options = Journal.Options(),
        lockTimeout: Duration
    ) async throws(PolicyError<StoreError>) -> Outbox {
        let journal = try await Journal.open(at: path, fileSystem: fileSystem, options: journalOptions, lockTimeout: lockTimeout)
        do throws(StoreError) {
            return try recover(journal, path: path, codec: codec, policy: policy, compactionThreshold: compactionThreshold)
        } catch {
            throw .failed(error)
        }
    }

    /// The pending entries, rebuilt from the snapshot and the log.
    private static func recover(
        _ journal: Journal, path: String, codec: OutboxCodec<Item>, policy: DeliveryPolicy, compactionThreshold: Int
    ) throws(StoreError) -> Outbox {
        let replay = try journal.replay()
        var pending = PendingQueue()
        if let snapshot = replay.snapshot {
            for stored in try Self.decodeSnapshot(snapshot.bytes, path: path) { pending.append(stored) }
        }
        for record in replay.records {
            switch try Self.decodeRecord(record.bytes, path: path) {
            case .enqueue(let key, let item, let enqueuedAt):
                pending.append(Stored(key: key, sequence: record.sequence, bytes: item, enqueuedAt: enqueuedAt))
            case .acknowledge(let key):
                pending.remove(key)
            }
        }
        return Outbox(journal: journal, codec: codec, policy: policy, compactionThreshold: compactionThreshold, pending: pending)
    }

    // MARK: Enqueue

    /// Persists `item` and returns the key it will be delivered under. The
    /// entry is durable when this returns.
    ///
    /// Passing a `key` that is already pending is a no-op that returns it: an
    /// enqueue is idempotent in its key, so a retried enqueue (the UI
    /// double-fired, a task re-ran) never queues twice *while the first is
    /// pending*. Once that entry has been delivered and acknowledged (or
    /// discarded) the outbox forgets the key: enqueueing it again is a new
    /// entry, delivered again under the same key, which a server that honours
    /// the key deduplicates and one that does not acts on twice. An operation
    /// must not be enqueued again after its delivery has been reported.
    @discardableResult
    public func enqueue(_ item: Item, key: IdempotencyKey = .random()) throws(StoreError) -> IdempotencyKey {
        if pending.contains(key) { return key }
        let encoded: [UInt8]
        do {
            encoded = try codec.encode(item)
        } catch {
            throw StoreError(kind: .invalidArgument, operation: "enqueue", detail: "the item could not be encoded: \(error)")
        }
        // Stamped only when the policy expires entries: an outbox that never
        // does writes the record format every earlier release reads.
        let enqueuedAt = policy.expiry.map { Self.milliseconds($0.wallClock()) }
        let record = try Self.enqueueRecord(key: key, item: encoded, enqueuedAt: enqueuedAt)
        let sequence = try journal.append(record)
        pending.append(Stored(key: key, sequence: sequence, bytes: encoded, enqueuedAt: enqueuedAt))
        return key
    }

    // MARK: Inspecting

    /// How many entries are waiting.
    public var pendingCount: Int { pending.count }

    /// The waiting entries' keys, in delivery order.
    public var pendingKeys: [IdempotencyKey] { pending.entries.map(\.key) }

    /// The waiting entries, decoded, in delivery order.
    ///
    /// - Throws: `.corrupt` if an item no longer decodes.
    public func entries() throws(StoreError) -> [Entry] {
        try pending.entries.map { (stored) throws(StoreError) in try decode(stored) }
    }

    private func decode(_ stored: Stored) throws(StoreError) -> Entry {
        do {
            return Entry(key: stored.key, item: try codec.decode(stored.bytes), sequence: stored.sequence)
        } catch {
            throw StoreError(kind: .corrupt, operation: "decode", detail: "entry \(stored.key) does not decode: \(error)")
        }
    }

    // MARK: Delivery

    /// Delivers every pending entry, in order, and acknowledges each one the
    /// moment `deliver` returns ``DeliveryResult/delivered`` (or
    /// ``DeliveryResult/discard(reason:)``, which drops it).
    ///
    /// `deliver` receives the entry; send ``Entry/key`` with the request.
    /// It runs inside `retry` on the policy's schedule, so it may be called
    /// several times for one entry. It says what became of the entry by what
    /// it returns (see ``DeliveryResult``); throwing leaves the entry pending.
    /// Throw an error that is `Retryable` with `.stop` (or a `Defect`) to
    /// give up on an entry for this run at once.
    ///
    /// Entries enqueued while a run is in progress wait for the next run.
    /// A call that starts while another delivery (a run, or a
    /// ``deliver(_:using:)``) is going returns immediately
    /// (``DeliveryReport/wasAlreadyRunning``).
    ///
    /// - Throws: `StoreError` if an acknowledgement could not be written (the
    ///   entry stays pending and will be delivered again), `CancellationError`
    ///   if cancelled.
    public func deliverPending(
        using deliver: (Entry) async throws -> DeliveryResult
    ) async throws -> DeliveryReport {
        var report = DeliveryReport()
        guard takeTurnIfFree() else {
            report.wasAlreadyRunning = true
            report.remaining = pending.count
            return report
        }
        defer { endTurn() }

        for stored in pending.entries {
            try Task.checkCancellation()
            let settled = try await attempt(stored, using: deliver)
            note(settled, for: stored.key, in: &report)
            if settled.stopsARun(under: policy.onFailure) { break }
        }
        // Maintenance is not worth starting for a caller that has gone.
        if !Task.isCancelled { compactIfNeeded() }
        report.remaining = pending.count
        return report
    }

    /// Delivers the one entry `key` names, waits for its outcome, and says
    /// what happened to *it*: for "save this, send it now, and tell me", while
    /// a schedule goes on draining the rest.
    ///
    /// Single flight holds: if a run (or another `deliver`) is going, this
    /// waits for it to end before it begins, so an entry is never attempted
    /// twice at once. If that run attempted the entry, its outcome is the
    /// answer and no second attempt is made; otherwise the entry (enqueued
    /// since the run began, say, or beyond the point where a failure stopped
    /// it) is attempted now, under the policy's schedule, and expiry and
    /// ``DeliveryPolicy/onUndecodable`` apply as in a run.
    ///
    /// It attempts exactly that entry: entries ahead of it are neither
    /// attempted nor waited for, so with ``DeliveryPolicy/FailureMode/stopAtFirst``
    /// it can overtake one that is failing. Use `deliverPending(using:)`
    /// when order matters more than this entry.
    ///
    /// - Returns: The outcome of the attempt that settled the entry; `.notPending`
    ///   if it is not in the outbox: never enqueued, or delivered or discarded
    ///   already (an outcome from before this call began is not kept).
    /// - Throws: `StoreError` if an acknowledgement could not be written (the
    ///   entry stays pending and will be delivered again), `CancellationError`
    ///   if cancelled, also while waiting its turn.
    public func deliver(
        _ key: IdempotencyKey,
        using deliver: (Entry) async throws -> DeliveryResult
    ) async throws -> DeliveryOutcome {
        // Registered before the wait: a run that is going may reach the entry
        // while this waits, and its outcome must not be missed.
        let watcher = nextWatcher
        nextWatcher += 1
        watchers[watcher] = Watcher(key: key, outcome: nil)
        defer { watchers[watcher] = nil }

        try await takeTurn()
        defer { endTurn() }
        if let outcome = watchers[watcher]?.outcome { return outcome }
        guard let stored = pending.stored(for: key) else { return .notPending }
        try Task.checkCancellation()
        let settled = try await attempt(stored, using: deliver)
        if !Task.isCancelled { compactIfNeeded() }
        return note(settled, for: stored.key)
    }

    /// What an entry's attempts came to, before it is reported.
    private enum Settled {
        case delivered(attempts: Int)
        case discarded(DiscardReason, attempts: Int)
        case failed(any Error, attempts: Int)
        case kept(attempts: Int)

        /// Whether a run goes no further: an entry that did not leave the queue
        /// for a reason of its own stops it under `.stopAtFirst`, so a later
        /// entry cannot overtake it.
        func stopsARun(under mode: DeliveryPolicy.FailureMode) -> Bool {
            switch self {
            case .delivered, .discarded: false
            case .failed, .kept: mode == .stopAtFirst
            }
        }
    }

    /// One entry's whole delivery: expiry, decoding, the attempts under
    /// `retry`, and the acknowledgement (or discard) they call for.
    private func attempt(
        _ stored: Stored, using deliver: (Entry) async throws -> DeliveryResult
    ) async throws -> Settled {
        if let expiry = policy.expiry, let enqueuedAt = stored.enqueuedAt,
            Self.isExpired(enqueuedAt: enqueuedAt, now: Self.milliseconds(expiry.wallClock()), maxAge: expiry.maxAge)
        {
            try acknowledge(stored.key)
            return .discarded(.expired, attempts: 0)
        }
        let entry: Entry
        do throws(StoreError) {
            entry = try decode(stored)
        } catch {
            switch policy.onUndecodable {
            case .discard:
                try acknowledge(stored.key)
                return .discarded(.undecodable, attempts: 0)
            case .keep:
                return .failed(error, attempts: 0)
            }
        }
        var attempts = 0
        let result: DeliveryResult
        do {
            // The entry's key is the attempts' key: a keyed `perform`
            // inside `deliver` derives its own from it, the same on every
            // attempt and every relaunch (design/22, Keys).
            result = try await retry(
                policy.schedule, idempotencyKey: stored.key, budget: policy.budget, classify: policy.classify,
                label: "outbox"
            ) { _ in
                attempts += 1
                return try await deliver(entry)
            }
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch where Task.isCancelled {
            // `retry` cancelled during its backoff rethrows the last
            // attempt's error, not `CancellationError`. The entry did not
            // fail: the run was cancelled, and it stays pending.
            throw CancellationError()
        } catch {
            return .failed(error, attempts: attempts)
        }
        switch result {
        case .delivered:
            try acknowledge(stored.key)
            return .delivered(attempts: attempts)
        case .discard(let reason):
            try acknowledge(stored.key)
            return .discarded(.refused(reason), attempts: attempts)
        case .keep:
            return .kept(attempts: attempts)
        }
    }

    /// Records a settled entry in a run's report, as events, and for any
    /// ``deliver(_:using:)`` waiting on it.
    private func note(_ settled: Settled, for key: IdempotencyKey, in report: inout DeliveryReport) {
        switch settled {
        case .delivered: report.delivered.append(key)
        case .discarded(let reason, let attempts): report.discarded.append(.init(key: key, reason: reason, attempts: attempts))
        case .failed(let error, let attempts): report.failed.append(.init(key: key, error: error, attempts: attempts))
        case .kept: report.kept.append(key)
        }
        note(settled, for: key)
    }

    @discardableResult
    private func note(_ settled: Settled, for key: IdempotencyKey) -> DeliveryOutcome {
        let outcome: DeliveryOutcome
        switch settled {
        case .delivered(let attempts):
            outcome = .delivered
            StoreEvents.record(Event("store.outbox_delivered", level: .debug, fields: [
                .init("key", .string(key.rawValue)), .init("attempts", .int(attempts)),
            ]))
        case .discarded(let reason, let attempts):
            outcome = .discarded(reason)
            StoreEvents.record(Event("store.outbox_discarded", level: .warning, fields: [
                .init("key", .string(key.rawValue)), .init("kind", .string(reason.kind)),
                .init("reason", .string(reason.description)), .init("attempts", .int(attempts)),
            ]))
        case .failed(let error, let attempts):
            outcome = .failed(error, attempts: attempts)
            StoreEvents.record(Event("store.outbox_delivery_failed", level: .warning, fields: [
                .init("key", .string(key.rawValue)), .init("attempts", .int(attempts)), .init("error", .error(error)),
            ]))
        case .kept(let attempts):
            outcome = .kept
            StoreEvents.record(Event("store.outbox_kept", level: .debug, fields: [
                .init("key", .string(key.rawValue)), .init("attempts", .int(attempts)),
            ]))
        }
        for id in watchers.keys where watchers[id]?.key == key && watchers[id]?.outcome == nil {
            watchers[id]?.outcome = outcome
        }
        return outcome
    }

    // MARK: One at a time

    /// How many ``deliver(_:using:)`` calls are waiting their turn: for the
    /// tests, which must know a call has met the delivery in progress before
    /// they let it finish.
    var waitingDeliveries: Int { turn.withLock { $0.queue.count } }

    /// Takes the turn if nobody holds it; a run that finds it taken gives up.
    private func takeTurnIfFree() -> Bool {
        turn.withLock { turn in
            if turn.held { return false }
            turn.held = true
            return true
        }
    }

    /// Takes the turn, waiting behind whoever holds it and whoever asked first.
    private func takeTurn() async throws {
        let id = turn.withLock { turn -> UInt64 in
            defer { turn.nextID += 1 }
            return turn.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let immediate = turn.withLock { turn -> Result<Void, CancellationError>? in
                    // Checked under the lock the cancellation handler takes: a
                    // cancel that came first is seen here, one that comes after
                    // finds the waiter queued.
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if !turn.held {
                        turn.held = true
                        return .success(())
                    }
                    turn.queue.append((id, continuation))
                    return nil
                }
                switch immediate {
                case .success?: continuation.resume()
                case .failure(let error)?: continuation.resume(throwing: error)
                case nil: break
                }
            }
        } onCancel: {
            let waiter = turn.withLock { turn -> CheckedContinuation<Void, any Error>? in
                guard let index = turn.queue.firstIndex(where: { $0.id == id }) else { return nil }
                return turn.queue.remove(at: index).continuation
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    /// Hands the turn to the first waiter, or frees it.
    private func endTurn() {
        let next = turn.withLock { turn -> CheckedContinuation<Void, any Error>? in
            if turn.queue.isEmpty {
                turn.held = false
                return nil
            }
            return turn.queue.removeFirst().continuation
        }
        next?.resume()
    }

    /// Drops an entry without delivering it: for an entry the app has decided
    /// can never be sent (it no longer decodes after an upgrade, the server
    /// says it is invalid). Durable when it returns.
    public func discard(_ key: IdempotencyKey) throws(StoreError) {
        try acknowledge(key)
    }

    private func acknowledge(_ key: IdempotencyKey) throws(StoreError) {
        guard pending.contains(key) else { return }
        try journal.append(try Self.acknowledgeRecord(key: key))
        pending.remove(key)
    }

    /// Folds the pending entries into a snapshot once the log is long. A
    /// failure here loses nothing (the log is still complete), so it is
    /// reported, not thrown: the delivery run's result matters more.
    private func compactIfNeeded() {
        guard journal.byteCount > compactionThreshold else { return }
        let snapshot = Self.encodeSnapshot(pending.entries)
        do throws(StoreError) {
            try journal.compact(snapshot: snapshot)
        } catch {
            StoreEvents.record(Event("store.outbox_maintenance_failed", level: .warning, fields: [
                .init("operation", .string("compact")), .init("error", .error(error)),
            ]))
        }
    }

    /// Stops using the files. Further calls throw.
    public func close() throws(StoreError) {
        try journal.close()
    }
}

// MARK: - Record formats

extension Outbox {
    enum Record {
        case enqueue(IdempotencyKey, [UInt8], enqueuedAt: Int64?)
        case acknowledge(IdempotencyKey)
    }

    static func keyBytes(_ key: IdempotencyKey) throws(StoreError) -> [UInt8] {
        let bytes = Array(key.rawValue.utf8)
        guard bytes.count <= 255 else {
            throw StoreError(kind: .invalidArgument, operation: "enqueue", detail: "an idempotency key is at most 255 bytes")
        }
        return bytes
    }

    /// `0x01 | keyLength:u8 | key | item`, or, for an entry that carries the
    /// time it was enqueued, `0x03 | keyLength:u8 | key | enqueuedAt:i64 | item`
    /// (milliseconds since 1970). The first is what every release has written
    /// and reads; the second is written only under ``DeliveryPolicy/expiry``.
    static func enqueueRecord(key: IdempotencyKey, item: [UInt8], enqueuedAt: Int64? = nil) throws(StoreError) -> [UInt8] {
        let key = try keyBytes(key)
        guard let enqueuedAt else { return [0x01, UInt8(key.count)] + key + item }
        return [0x03, UInt8(key.count)] + key + littleEndian(UInt64(bitPattern: enqueuedAt)) + item
    }

    /// `0x02 | keyLength:u8 | key`
    static func acknowledgeRecord(key: IdempotencyKey) throws(StoreError) -> [UInt8] {
        let key = try keyBytes(key)
        return [0x02, UInt8(key.count)] + key
    }

    static func decodeRecord(_ bytes: [UInt8], path: String) throws(StoreError) -> Record {
        func corrupt(_ why: String) -> StoreError {
            StoreError(kind: .corrupt, operation: "outbox", path: path, detail: why)
        }
        guard bytes.count >= 2 else { throw corrupt("record too short") }
        let keyEnd = 2 + Int(bytes[1])
        guard bytes.count >= keyEnd else { throw corrupt("record shorter than its key") }
        let key = IdempotencyKey(rawValue: String(decoding: bytes[2..<keyEnd], as: UTF8.self))
        switch bytes[0] {
        case 0x01: return .enqueue(key, Array(bytes[keyEnd...]), enqueuedAt: nil)
        case 0x02: return .acknowledge(key)
        case 0x03:
            guard bytes.count >= keyEnd + 8 else { throw corrupt("record shorter than its timestamp") }
            let enqueuedAt: UInt64 = readLittleEndian(bytes, at: keyEnd)
            return .enqueue(key, Array(bytes[(keyEnd + 8)...]), enqueuedAt: Int64(bitPattern: enqueuedAt))
        default: throw corrupt("unknown record type \(bytes[0])")
        }
    }

    /// `count:u32 | (sequence:u64 | keyLength:u8 | key | itemLength:u32 | item)*`,
    /// or, when any entry carries the time it was enqueued, the same with the
    /// top bit of `count` set and each entry's `enqueuedAt:i64` (`Int64.min`
    /// for none) after its `sequence`. The first is what every release has
    /// written; the second only appears under ``DeliveryPolicy/expiry``.
    private static func encodeSnapshot(_ entries: [Stored]) -> [UInt8] {
        let stamped = entries.contains { $0.enqueuedAt != nil }
        var bytes = littleEndian(UInt32(entries.count) | (stamped ? Self.stampedFlag : 0))
        for entry in entries {
            let key = Array(entry.key.rawValue.utf8)
            bytes += littleEndian(entry.sequence)
            if stamped { bytes += littleEndian(UInt64(bitPattern: entry.enqueuedAt ?? .min)) }
            bytes += [UInt8(key.count)] + key + littleEndian(UInt32(entry.bytes.count)) + entry.bytes
        }
        return bytes
    }

    private static var stampedFlag: UInt32 { 0x8000_0000 }

    /// Whole milliseconds in `time` (since 1970, for a wall-clock reading).
    static func milliseconds(_ time: Duration) -> Int64 {
        let parts = time.components
        return parts.seconds &* 1000 &+ parts.attoseconds / 1_000_000_000_000_000
    }

    /// Whether an entry enqueued at `enqueuedAt` is `maxAge` old at `now`
    /// (both wall-clock milliseconds). A clock that has gone backwards makes an
    /// entry younger, never expired.
    static func isExpired(enqueuedAt: Int64, now: Int64, maxAge: Duration) -> Bool {
        let (age, overflow) = now.subtractingReportingOverflow(enqueuedAt)
        guard !overflow, age >= 0 else { return false }
        return Duration.milliseconds(age) >= maxAge
    }

    private static func decodeSnapshot(_ bytes: [UInt8], path: String) throws(StoreError) -> [Stored] {
        func corrupt() -> StoreError {
            StoreError(kind: .corrupt, operation: "outbox snapshot", path: path, detail: "malformed")
        }
        guard bytes.count >= 4 else { throw corrupt() }
        let header = readLittleEndian(bytes, at: 0) as UInt32
        let stamped = header & stampedFlag != 0
        let count = Int(header & ~stampedFlag)
        var offset = 4
        var entries: [Stored] = []
        for _ in 0..<count {
            guard bytes.count >= offset + (stamped ? 17 : 9) else { throw corrupt() }
            let sequence: UInt64 = readLittleEndian(bytes, at: offset)
            offset += 8
            var enqueuedAt: Int64?
            if stamped {
                let stamp = Int64(bitPattern: readLittleEndian(bytes, at: offset) as UInt64)
                enqueuedAt = stamp == .min ? nil : stamp
                offset += 8
            }
            let keyLength = Int(bytes[offset])
            offset += 1
            guard bytes.count >= offset + keyLength + 4 else { throw corrupt() }
            let key = IdempotencyKey(rawValue: String(decoding: bytes[offset..<offset + keyLength], as: UTF8.self))
            offset += keyLength
            let length = Int(readLittleEndian(bytes, at: offset) as UInt32)
            offset += 4
            guard bytes.count >= offset + length else { throw corrupt() }
            entries.append(Stored(key: key, sequence: sequence, bytes: Array(bytes[offset..<offset + length]), enqueuedAt: enqueuedAt))
            offset += length
        }
        guard offset == bytes.count else { throw corrupt() }
        return entries
    }
}
