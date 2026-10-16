public import Stoic

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
///   ``DeliveryPolicy/FailureMode``.
/// - **Retry.** Each attempt sequence runs under Stoic's `retry` with the
///   policy's bounded schedule and classifier, so a `Retryable` error that
///   says `.stop` (a 4xx, say) is not retried. When the schedule is spent the
///   entry stays pending for the next run; nothing is dropped. A declared
///   operation's `perform` inside `deliver` that gives up settles the
///   attempt, which is then not repeated in this run (design/22).
/// - **Keys inside.** The entry's key is the enclosing key of every attempt:
///   a `.keyed` operation performed inside `deliver` without a key of its own
///   derives one from it, the same on every attempt and every relaunch.
///
///       try await outbox.deliverPending { entry in
///           try await Payments.subscribe.perform { attempt in
///               try await api.subscribe(entry.item, idempotencyKey: attempt.idempotencyKey)
///           }
///       }
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

        /// Entries delivered and acknowledged, in order.
        public var delivered: [IdempotencyKey] = []
        /// Entries that exhausted their attempts (or failed permanently) in this run.
        public var failed: [Failure] = []
        /// How many entries are still pending afterwards.
        public var remaining = 0
        /// `true` if another `deliverPending` was already running; this call did nothing.
        public var wasAlreadyRunning = false
    }

    private struct Stored {
        let key: IdempotencyKey
        let sequence: UInt64
        let bytes: [UInt8]
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
    private var delivering = false

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
            case .enqueue(let key, let item):
                pending.append(Stored(key: key, sequence: record.sequence, bytes: item))
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
        let record = try Self.enqueueRecord(key: key, item: encoded)
        let sequence = try journal.append(record)
        pending.append(Stored(key: key, sequence: sequence, bytes: encoded))
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
    /// moment `deliver` returns without throwing.
    ///
    /// `deliver` receives the entry; send ``Entry/key`` with the request.
    /// It runs inside `retry` on the policy's schedule, so it may be called
    /// several times for one entry. Throw an error that is `Retryable` with
    /// `.stop` (or a `Defect`) to give up on an entry at once.
    ///
    /// Entries enqueued while a run is in progress wait for the next run.
    /// A second call during a run returns immediately (``DeliveryReport/wasAlreadyRunning``).
    ///
    /// - Throws: `StoreError` if an acknowledgement could not be written (the
    ///   entry stays pending and will be delivered again), `CancellationError`
    ///   if cancelled.
    public func deliverPending(
        using deliver: (Entry) async throws -> Void
    ) async throws -> DeliveryReport {
        var report = DeliveryReport()
        guard !delivering else {
            report.wasAlreadyRunning = true
            report.remaining = pending.count
            return report
        }
        delivering = true
        defer { delivering = false }

        for stored in pending.entries {
            try Task.checkCancellation()
            var attempts = 0
            do {
                let entry = try decode(stored)
                // The entry's key is the attempts' key: a keyed `perform`
                // inside `deliver` derives its own from it, the same on every
                // attempt and every relaunch (design/22, Keys).
                try await retry(
                    policy.schedule, idempotencyKey: stored.key, budget: policy.budget, classify: policy.classify,
                    label: "outbox"
                ) { _ in
                    attempts += 1
                    try await deliver(entry)
                }
            } catch let cancellation as CancellationError {
                throw cancellation
            } catch where Task.isCancelled {
                // `retry` cancelled during its backoff rethrows the last
                // attempt's error, not `CancellationError`. The entry did not
                // fail: the run was cancelled, and it stays pending.
                throw CancellationError()
            } catch {
                report.failed.append(.init(key: stored.key, error: error, attempts: attempts))
                StoreEvents.record(Event("store.outbox_delivery_failed", level: .warning, fields: [
                    .init("key", .string(stored.key.rawValue)), .init("attempts", .int(attempts)), .init("error", .error(error)),
                ]))
                if policy.onFailure == .stopAtFirst { break }
                continue
            }
            try acknowledge(stored.key)
            report.delivered.append(stored.key)
            StoreEvents.record(Event("store.outbox_delivered", level: .debug, fields: [
                .init("key", .string(stored.key.rawValue)), .init("attempts", .int(attempts)),
            ]))
        }
        // Maintenance is not worth starting for a caller that has gone.
        if !Task.isCancelled { compactIfNeeded() }
        report.remaining = pending.count
        return report
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

/// How an ``Outbox`` delivers.
public struct DeliveryPolicy: Sendable {
    /// What a failed entry does to the rest of the run.
    public enum FailureMode: Sendable, Hashable {
        /// Stop the run: later entries must not overtake a failed one.
        case stopAtFirst
        /// Leave the entry pending and try the next: for independent entries.
        case continueWithNext
    }

    /// The attempts each entry gets per run, and the waits between them.
    public var schedule: BoundedSchedule

    /// Which failures are worth another attempt. The default retries
    /// anything not known to be permanent.
    public var classify: RetryClassifier<any Error>

    /// Caps retries relative to successful deliveries, so a long outage does
    /// not turn into a retry storm on the first launch after it. Each policy
    /// made with the default has its own budget.
    public var budget: RetryBudget

    public var onFailure: FailureMode

    public init(
        schedule: BoundedSchedule = .exponential(base: .seconds(1)).capped(at: .seconds(30)).attempts(4),
        classify: RetryClassifier<any Error> = .standard,
        budget: RetryBudget = RetryBudget(),
        onFailure: FailureMode = .stopAtFirst
    ) {
        self.schedule = schedule
        self.classify = classify
        self.budget = budget
        self.onFailure = onFailure
    }
}

// MARK: - Record formats

extension Outbox {
    enum Record {
        case enqueue(IdempotencyKey, [UInt8])
        case acknowledge(IdempotencyKey)
    }

    static func keyBytes(_ key: IdempotencyKey) throws(StoreError) -> [UInt8] {
        let bytes = Array(key.rawValue.utf8)
        guard bytes.count <= 255 else {
            throw StoreError(kind: .invalidArgument, operation: "enqueue", detail: "an idempotency key is at most 255 bytes")
        }
        return bytes
    }

    /// `0x01 | keyLength:u8 | key | item`
    static func enqueueRecord(key: IdempotencyKey, item: [UInt8]) throws(StoreError) -> [UInt8] {
        let key = try keyBytes(key)
        return [0x01, UInt8(key.count)] + key + item
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
        case 0x01: return .enqueue(key, Array(bytes[keyEnd...]))
        case 0x02: return .acknowledge(key)
        default: throw corrupt("unknown record type \(bytes[0])")
        }
    }

    /// `count:u32 | (sequence:u64 | keyLength:u8 | key | itemLength:u32 | item)*`
    private static func encodeSnapshot(_ entries: [Stored]) -> [UInt8] {
        var bytes = littleEndian(UInt32(entries.count))
        for entry in entries {
            let key = Array(entry.key.rawValue.utf8)
            bytes += littleEndian(entry.sequence) + [UInt8(key.count)] + key + littleEndian(UInt32(entry.bytes.count)) + entry.bytes
        }
        return bytes
    }

    private static func decodeSnapshot(_ bytes: [UInt8], path: String) throws(StoreError) -> [Stored] {
        func corrupt() -> StoreError {
            StoreError(kind: .corrupt, operation: "outbox snapshot", path: path, detail: "malformed")
        }
        guard bytes.count >= 4 else { throw corrupt() }
        let count = Int(readLittleEndian(bytes, at: 0) as UInt32)
        var offset = 4
        var entries: [Stored] = []
        for _ in 0..<count {
            guard bytes.count >= offset + 9 else { throw corrupt() }
            let sequence: UInt64 = readLittleEndian(bytes, at: offset)
            let keyLength = Int(bytes[offset + 8])
            offset += 9
            guard bytes.count >= offset + keyLength + 4 else { throw corrupt() }
            let key = IdempotencyKey(rawValue: String(decoding: bytes[offset..<offset + keyLength], as: UTF8.self))
            offset += keyLength
            let length = Int(readLittleEndian(bytes, at: offset) as UInt32)
            offset += 4
            guard bytes.count >= offset + length else { throw corrupt() }
            entries.append(Stored(key: key, sequence: sequence, bytes: Array(bytes[offset..<offset + length])))
            offset += length
        }
        guard offset == bytes.count else { throw corrupt() }
        return entries
    }
}
