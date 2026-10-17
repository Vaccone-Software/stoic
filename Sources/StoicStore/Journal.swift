public import Stoic
internal import Synchronization

/// An append-only log of records that survives a crash.
///
/// Every record is framed with its length and a CRC-32C, and `append` does
/// not return until the record is on stable storage (`fullSync`). Opening a
/// journal finds the last intact record and cuts everything after it: a
/// record torn by a crash, or a hole of zeros from a reordered write, is
/// dropped and reported (`store.journal_truncated`), never returned.
///
///     let journal = try Journal.open(at: dir + "/events.log")
///     let sequence = try journal.append(encode(event))         // durable
///
///     let state = try journal.replay()                         // after a relaunch
///     var model = decode(state.snapshot?.bytes)
///     for record in state.records { model.apply(decode(record.bytes)) }
///
///     try journal.compact { replay in encode(fold(replay)) }   // bound the log
///
/// ## Format
///
/// A record is `length:u32 | crc:u32 | sequence:u64 | payload`, little-endian.
/// `length` counts the sequence and payload in its low 30 bits; its top two
/// bits tie the records of a batch together (`more` follow, `joined` to the
/// one before), and are zero on a record appended alone. `crc` is the
/// CRC-32C of the four length bytes followed by those `length` bytes, so a
/// flipped length is as visible as a flipped payload, and a hole of zeros is
/// never a valid record. Sequence numbers are strictly increasing across the
/// log, and across compactions.
///
/// ## Compaction
///
/// `compact` writes a snapshot with ``AtomicFile`` (`<path>.snapshot`), naming
/// the last sequence it covers, and *then* truncates the log. The order, and
/// the sequence number, make every crash point safe:
///
/// - before the snapshot is durable: the old snapshot and the whole log;
/// - after it but before the truncation is durable: the new snapshot, and a
///   log whose records are all at or below its sequence, so they are skipped
///   (and the next `open` finishes the truncation);
/// - after: the new snapshot and an empty log.
///
/// A snapshot that fails its checksum is quarantined and `open` throws
/// `.corrupt`: the log before it was discarded, so there is nothing safe to
/// fall back to, and silently starting empty would hide data loss. The
/// refusal is sticky: a tombstone (`<path>.snapshot-lost`), made durable
/// before the snapshot is moved aside, makes every later `open` throw too,
/// until one passes ``Options/LostSnapshot/acceptLoss`` and reads
/// ``OpenReport/lostSnapshot``.
///
/// ## Failures
///
/// A failed write is rolled back by truncating to the last good end. A failed
/// `fullSync` leaves the outcome unknown (the kernel may have dropped the
/// pages), and a later successful sync would prove nothing, so the journal is
/// *poisoned*: every call throws `.poisoned` until it is reopened, which
/// re-reads the file and settles the question. A record whose append threw may
/// therefore still be there after recovery; callers that cannot tolerate
/// duplicates deduplicate by content (the ``Outbox`` does, by key).
///
/// ## Contract
///
/// Safe to call from many threads; calls are serialised and blocking. One
/// `Journal` per path per process, and one process per path unless
/// ``Options/crossProcessLock`` is set. The log is read whole at open and by
/// `replay`, so compact when it grows: the journal is for small, important
/// state, not for a database's worth of data.
public final class Journal: Sendable {
    public struct Options: Sendable, Hashable {
        /// What `open` does on finding damage in the middle of the log: a bad
        /// record with intact records after it. (Damage with nothing intact
        /// after it is a torn tail, cut as always.)
        public enum MiddleDamage: Sendable, Hashable {
            /// Keep the intact records after the damage, leave the damaged
            /// bytes where they are, and report them (``OpenReport/corruption``,
            /// `store.journal_corruption`). Nothing intact is lost.
            case skipAndReport
            /// Throw `.corrupt` and touch nothing, for a caller that cannot
            /// tolerate a gap in its history and would rather recover by hand.
            case refuse
        }

        /// What `open` does once the snapshot has been lost.
        public enum LostSnapshot: Sendable, Hashable {
            /// Throw `.corrupt`, on this open and every later one: the
            /// records the snapshot folded in are gone, and opening as if
            /// nothing happened would hide that.
            case refuse
            /// Open without the snapshot, replaying every intact record left
            /// in the log, and say so in ``OpenReport/lostSnapshot``. The
            /// acceptance is recorded: later opens no longer refuse.
            case acceptLoss
        }

        /// The largest payload `append` accepts. The format frames at most
        /// 1 GiB less 9 bytes, whatever this says.
        public var maxRecordSize: Int

        /// What `open` does with damage in the middle of the log.
        public var middleDamage: MiddleDamage

        /// What `open` does when the snapshot was lost. Refuses by default.
        public var lostSnapshot: LostSnapshot

        /// Hold an advisory lock on `<path>.lock` for as long as the journal
        /// is open, so a second process cannot open it for writing: its `open`
        /// throws `.busy` (or waits, with `open(at:fileSystem:options:lockTimeout:)`).
        /// The OS frees the lock when the process dies. Off by default. See
        /// ``FileLock`` for what an advisory lock does not protect (network
        /// volumes, writers that do not take it).
        public var crossProcessLock: Bool

        public init(
            maxRecordSize: Int = 16 * 1024 * 1024, middleDamage: MiddleDamage = .skipAndReport,
            crossProcessLock: Bool = false, lostSnapshot: LostSnapshot = .refuse
        ) {
            self.maxRecordSize = maxRecordSize
            self.middleDamage = middleDamage
            self.crossProcessLock = crossProcessLock
            self.lostSnapshot = lostSnapshot
        }
    }

    /// A stretch of the log that failed verification with intact records
    /// after it, and was skipped.
    public struct Corruption: Sendable, Hashable {
        /// Where the damaged bytes start, in the log file.
        public let offset: Int
        /// How many bytes were skipped.
        public let length: Int
        /// How many records the skipped stretch held, counted from the gap in
        /// sequence numbers between the intact records on either side of it
        /// (records a snapshot already covers are not counted: nothing was lost).
        public let lostRecords: Int
        /// The sequence number of the first record lost, if any.
        public let firstLostSequence: UInt64?
    }

    /// One durable record.
    public struct Record: Sendable, Hashable {
        public let sequence: UInt64
        public let bytes: [UInt8]
    }

    /// The state folded into a compaction.
    public struct Snapshot: Sendable, Hashable {
        /// The last sequence the snapshot covers.
        public let through: UInt64
        public let bytes: [UInt8]
    }

    /// Everything needed to rebuild state: the snapshot, then the records after it.
    public struct Replay: Sendable, Hashable {
        public let snapshot: Snapshot?
        public let records: [Record]

        /// The sequence a compaction of this replay is recorded against: the
        /// last record's, or the snapshot's when no record follows it (0 for
        /// an empty journal). It is ``Journal/lastSequence`` as of the replay.
        public var lastSequence: UInt64 { records.last?.sequence ?? snapshot?.through ?? 0 }
    }

    /// What opening found and repaired.
    public struct OpenReport: Sendable, Hashable {
        /// Bytes cut from the end because they were torn or corrupt.
        public let droppedBytes: Int
        /// Intact records that a snapshot already covers (a compaction was interrupted).
        public let staleRecords: Int
        /// Records that remain to replay.
        public let records: Int
        /// Damage found in the middle of the log and skipped; empty if none.
        public let corruption: [Corruption]
        /// The snapshot had been lost, and this open accepted it
        /// (``Options/LostSnapshot/acceptLoss``): whatever it folded in is
        /// gone, and the records replayed are only those the log still held.
        public let lostSnapshot: Bool

        /// How many records were lost to ``corruption``.
        public var corruptRecords: Int { corruption.reduce(0) { $0 + $1.lostRecords } }

        init(droppedBytes: Int, staleRecords: Int, records: Int, corruption: [Corruption] = [], lostSnapshot: Bool = false) {
            self.droppedBytes = droppedBytes
            self.staleRecords = staleRecords
            self.records = records
            self.corruption = corruption
            self.lostSnapshot = lostSnapshot
        }
    }

    public let path: String
    public let fileSystem: any FileSystem
    public let options: Options
    public let openReport: OpenReport

    private struct State {
        var file: OpenFile?
        var end: Int
        var lastSequence: UInt64
        var snapshot: Snapshot?
        var poison: StoreError?
        /// Damage skipped in the middle of the log at open, still in the file
        /// until a compaction cuts it.
        var corruption: [Corruption]
    }

    private let state: Mutex<State>
    /// The cross-process lock, held from `open` until `close` (or deinit).
    private let lock: FileLock?

    private var snapshotPath: String { path + ".snapshot" }

    private init(path: String, fileSystem: any FileSystem, options: Options, report: OpenReport, state: State, lock: FileLock?) {
        self.lock = lock
        self.path = path
        self.fileSystem = fileSystem
        self.options = options
        self.openReport = report
        self.state = Mutex(state)
    }

    deinit {
        // A journal dropped without `close()` still releases its descriptor.
        // Nothing can be reported from a deinit, and every record is already
        // durable (append syncs before returning), so a failed close loses nothing.
        if let file = state.withLock({ $0.file }) {
            do throws(StoreError) {
                try fileSystem.close(file)
            } catch {}  // stoic:allow(swallowed-error): nothing can be reported from a deinit (see above)
        }
    }

    // MARK: Opening

    /// Opens the journal at `path`, repairing a torn tail and finishing an
    /// interrupted compaction.
    ///
    /// With ``Options/crossProcessLock``, throws `.busy` if another process
    /// (or journal) holds the lock; nothing is read or changed.
    public static func open(
        at path: String,
        fileSystem: any FileSystem = PosixFileSystem(),
        options: Options = Options()
    ) throws(StoreError) -> Journal {
        var lock: FileLock?
        if options.crossProcessLock {
            let candidate = FileLock(path: path + ".lock", fileSystem: fileSystem)
            guard try candidate.tryAcquire() else {
                throw StoreError(kind: .busy, operation: "flock", path: path + ".lock", detail: "another process holds the journal")
            }
            lock = candidate
        }
        return try open(at: path, fileSystem: fileSystem, options: options, holding: lock)
    }

    /// ``open(at:fileSystem:options:)``, waiting up to `lockTimeout` for
    /// another process to let go of the journal's lock.
    ///
    /// The wait polls the ambient clock and honours cancellation and
    /// `Deadline.current`; it never blocks a thread. Without
    /// ``Options/crossProcessLock`` there is nothing to wait for.
    public static func open(
        at path: String,
        fileSystem: any FileSystem = PosixFileSystem(),
        options: Options = Options(),
        lockTimeout: Duration
    ) async throws(PolicyError<StoreError>) -> Journal {
        var lock: FileLock?
        if options.crossProcessLock {
            let candidate = FileLock(path: path + ".lock", fileSystem: fileSystem)
            try await candidate.acquire(timeout: lockTimeout)
            lock = candidate
        }
        do throws(StoreError) {
            return try open(at: path, fileSystem: fileSystem, options: options, holding: lock)
        } catch {
            throw .failed(error)
        }
    }

    /// Opens with `lock` (already held, or `nil`); releases it if the open fails.
    private static func open(
        at path: String, fileSystem: any FileSystem, options: Options, holding lock: FileLock?
    ) throws(StoreError) -> Journal {
        do throws(StoreError) {
            return try openLocked(at: path, fileSystem: fileSystem, options: options, lock: lock)
        } catch {
            do throws(StoreError) {
                try lock?.release()
            } catch {
                // The open's failure is the one worth reporting.
            }
            throw error
        }
    }

    private static func openLocked(
        at path: String, fileSystem: any FileSystem, options: Options, lock: FileLock?
    ) throws(StoreError) -> Journal {
        let directory = StorePath.directory(of: path)
        let lostSnapshot = try checkLostSnapshot(at: path, fileSystem: fileSystem, options: options)
        let snapshot = lostSnapshot ? nil : try loadSnapshot(path + ".snapshot", fileSystem: fileSystem)

        let created = try !fileSystem.exists(path)
        let file = try fileSystem.open(path, mode: .readWriteCreate)
        do throws(StoreError) {
            if created { try fileSystem.syncDirectory(directory) }   // the name is part of the data

            let size = try fileSystem.size(of: file)
            let contents = try fileSystem.read(file, at: 0, count: size)
            let through = snapshot?.through ?? 0
            let scan = Journal.scan(contents, maxRecordSize: options.maxRecordSize, after: through)
            if let first = scan.corruption.first, options.middleDamage == .refuse {
                // Before anything is changed, not even a torn tail cut.
                throw StoreError(
                    kind: .corrupt, operation: "open", path: path,
                    detail: "\(first.length) bytes at offset \(first.offset) fail verification with intact records after them (\(scan.corruption.count) such stretches, \(scan.corruption.reduce(0) { $0 + $1.lostRecords }) records lost); the file was left untouched"
                )
            }

            var end = scan.validEnd
            if end < size {
                try fileSystem.truncate(file, to: end)
                try fileSystem.fullSync(file)
                StoreEvents.record(Event("store.journal_truncated", level: .warning, fields: [
                    .init("path", .string(path)), .init("droppedBytes", .int(size - end)),
                    .init("validRecords", .int(scan.records.count)),
                ]))
            }
            for damage in scan.corruption {
                var fields: [Event.Field] = [
                    .init("path", .string(path)), .init("offset", .int(damage.offset)), .init("length", .int(damage.length)),
                    .init("lostRecords", .int(damage.lostRecords)),
                ]
                if let first = damage.firstLostSequence { fields.append(.init("firstLostSequence", .int(Int(truncatingIfNeeded: first)))) }
                StoreEvents.record(Event("store.journal_corruption", level: .error, fields: fields))
            }
            var inLog = scan.records
            let stale = inLog.prefix { $0.sequence <= through }.count
            if stale == inLog.count, stale > 0 {
                // Every record is covered by the snapshot: a compaction stopped
                // between writing the snapshot and truncating the log. Finish it.
                try fileSystem.truncate(file, to: 0)
                try fileSystem.fullSync(file)
                end = 0
                inLog = []
            }
            let report = OpenReport(
                droppedBytes: size - scan.validEnd, staleRecords: stale,
                records: inLog.count - (end == 0 ? 0 : stale), corruption: scan.corruption, lostSnapshot: lostSnapshot
            )
            if lostSnapshot {
                // Accepted: later opens no longer refuse. A crash before the
                // removal is durable only means the next open is asked again.
                try fileSystem.remove(path + Self.lostSnapshotSuffix)
                try fileSystem.syncDirectory(directory)
            }
            let state = State(
                file: file, end: end,
                lastSequence: max(through, scan.records.last?.sequence ?? 0),
                snapshot: snapshot, poison: nil, corruption: end == 0 ? [] : scan.corruption
            )
            return Journal(path: path, fileSystem: fileSystem, options: options, report: report, state: state, lock: lock)
        } catch {
            do throws(StoreError) {
                try fileSystem.close(file)
            } catch {
                // The open failed for another reason; report that one.
            }
            throw error
        }
    }

    static let lostSnapshotSuffix = ".snapshot-lost"

    /// Whether the snapshot was lost and `options` accept that; throws if it
    /// was lost and they do not.
    ///
    /// A corrupt snapshot is found here, and the tombstone recording its loss
    /// is made durable *before* the snapshot is quarantined: a crash between
    /// the two leaves both, never a journal that opens as if it had none.
    private static func checkLostSnapshot(at path: String, fileSystem: any FileSystem, options: Options) throws(StoreError) -> Bool {
        let snapshotPath = path + ".snapshot"
        let tombstone = path + lostSnapshotSuffix
        let store = AtomicFile(fileSystem: fileSystem)
        var lost = try fileSystem.exists(tombstone)
        if !lost, try fileSystem.exists(snapshotPath), case .failure = Envelope.open(try fileSystem.readAll(snapshotPath)) {
            try store.write(Array("stoic.journal snapshot-lost v1".utf8), to: tombstone)
            lost = true
        }
        guard lost else { return false }
        if try fileSystem.exists(snapshotPath) {
            store.quarantine(snapshotPath, reason: "snapshot failed its checksum", options: store.options)
        }
        let accepted = options.lostSnapshot == .acceptLoss
        StoreEvents.record(Event("store.journal_snapshot_lost", level: .error, fields: [
            .init("path", .string(path)), .init("accepted", .bool(accepted)),
        ]))
        guard accepted else {
            throw StoreError(
                kind: .corrupt, operation: "snapshot", path: snapshotPath,
                detail: "the snapshot was lost (quarantined as corrupt), and the records it folded in with it; open with lostSnapshot: .acceptLoss to continue without them"
            )
        }
        return true
    }

    private static func loadSnapshot(_ path: String, fileSystem: any FileSystem) throws(StoreError) -> Snapshot? {
        guard let stored = try AtomicFile(fileSystem: fileSystem).read(path) else { return nil }
        guard stored.bytes.count >= 8 else {
            throw StoreError(kind: .corrupt, operation: "snapshot", path: path, detail: "too short for a sequence number")
        }
        return Snapshot(through: readLittleEndian(stored.bytes, at: 0), bytes: Array(stored.bytes[8...]))
    }

    // MARK: Framing

    static let headerSize = 16   // length, crc, sequence

    /// The top two bits of `length` tie the records of a batch together:
    /// `more` on every record but the last, `joined` on every record but the
    /// first. A record appended alone has neither, which is the format every
    /// earlier release wrote, so their logs read as they always did.
    static let moreFlag: UInt32 = 1 << 31
    static let joinedFlag: UInt32 = 1 << 30
    static let lengthMask: UInt32 = joinedFlag - 1

    /// The largest payload the format can frame: `length` (payload and
    /// sequence) has 30 bits.
    static let largestPayload = Int(lengthMask) - 8

    static func frame(_ payload: [UInt8], sequence: UInt64, more: Bool = false, joined: Bool = false) -> [UInt8] {
        let length = UInt32(payload.count + 8) | (more ? moreFlag : 0) | (joined ? joinedFlag : 0)
        let lengthBytes = littleEndian(length)
        let body = littleEndian(sequence) + payload
        var crc = CRC32C.Running()
        crc.update(lengthBytes)
        crc.update(body)
        return lengthBytes + littleEndian(crc.value) + body
    }

    /// What a scan of the log found.
    struct Scan {
        /// The intact records, in order, with damaged stretches between them skipped.
        var records: [Record] = []
        /// Where the last intact record ends. Whatever follows is a torn tail.
        var validEnd = 0
        /// Damaged stretches with intact records after them.
        var corruption: [Corruption] = []
    }

    /// One frame that verified.
    private struct Frame {
        let record: Record
        let end: Int
        /// More records of its batch follow it.
        let more: Bool
        /// It is not the first record of its batch.
        let joined: Bool
    }

    /// A frame is intact when it fits, is within the size limit, has a valid
    /// checksum and carries a sequence number above `previous`.
    private static func intactFrame(
        in bytes: [UInt8], at offset: Int, after previous: UInt64, maxRecordSize: Int
    ) -> Frame? {
        guard bytes.count - offset >= headerSize else { return nil }
        let field: UInt32 = readLittleEndian(bytes, at: offset)
        let length = Int(field & lengthMask)
        guard length >= 8, length - 8 <= maxRecordSize, offset + 8 + length <= bytes.count else { return nil }
        let stored: UInt32 = readLittleEndian(bytes, at: offset + 4)
        var crc = CRC32C.Running()
        crc.update(bytes[offset..<offset + 4])
        crc.update(bytes[offset + 8..<offset + 8 + length])
        guard crc.value == stored else { return nil }
        let sequence: UInt64 = readLittleEndian(bytes, at: offset + 8)
        guard sequence > previous else { return nil }
        return Frame(
            record: Record(sequence: sequence, bytes: Array(bytes[offset + 16..<offset + 8 + length])),
            end: offset + 8 + length, more: field & moreFlag != 0, joined: field & joinedFlag != 0
        )
    }

    /// The intact records of `bytes`, where the last one ends, and the
    /// damaged stretches skipped between them.
    ///
    /// A bad frame is either a **torn tail** (a crash cut the last write, or
    /// left a hole of zeros), or **damage in the middle** (a flipped bit, a
    /// bad sector) with records after it. They are told apart by looking
    /// ahead: if some later offset holds an intact frame, the stretch up to it
    /// is damage, skipped, and the scan carries on there; if none does, the
    /// bad frame and everything after it is a tail, and `validEnd` stops
    /// before it. A flipped bit in the *last* record is therefore a tail,
    /// which no format without a marker could tell from a crash.
    ///
    /// The format has no sync marker, so "intact frame" is the only signal:
    /// a length that fits, a CRC-32C that matches, a sequence above the last.
    /// A candidate must also be *plausible*: the records missing between it
    /// and the last good one (the gap in sequence numbers) must fit in the
    /// bytes skipped, at no fewer than `headerSize` each. That rejects a
    /// framed record that happens to sit inside a damaged payload, unless its
    /// sequence number is also just right (see design/15).
    ///
    /// **A batch is all or nothing, unless a later one proves it was kept.**
    /// A batch's records are one write, and a crash may keep any of its pages
    /// and not others, so its records are held back until its last one (the
    /// one without `more`) verifies. A batch cut short by a bad frame with no
    /// later batch after it is a torn tail, dropped whole: a crash during a
    /// batch never leaves part of it. A later batch is proof the damaged one
    /// was acknowledged (appends are serial, each synced before the next
    /// begins), so then the damage is in the middle and every record of the
    /// damaged batch that verifies is kept, as for single records.
    ///
    /// - Parameter through: The last sequence a snapshot covers, which the
    ///   first record's gap is measured from.
    static func scan(_ bytes: [UInt8], maxRecordSize: Int, after through: UInt64 = 0) -> Scan {
        var scan = Scan()
        var offset = 0
        // The last record committed, and the batch being read.
        var committed: UInt64 = 0
        var batch: [Record] = []
        var batchStart = 0
        // Damage skipped just before the batch being read: it counts only if
        // the batch completes.
        var damageBeforeBatch: Corruption?
        // Inside a damaged batch that a later one (starting here) proves was
        // acknowledged: its intact records count as they come.
        var salvageUntil: Int?

        func commit(_ records: [Record], end: Int) {
            if let damage = damageBeforeBatch { scan.corruption.append(damage) }
            damageBeforeBatch = nil
            scan.records += records
            scan.validEnd = end
            committed = records.last!.sequence
        }

        /// The nearest offset in `range` holding an intact frame (one that
        /// starts a batch, if `batchStart`) whose gap in sequence numbers fits
        /// the bytes skipped since `damageStart`, and the records that gap says
        /// were lost.
        func plausible(in range: ClosedRange<Int>, damageStart: Int, batchStart: Bool) -> (offset: Int, lost: Int, baseline: UInt64)? {
            let baseline = max(committed, through)
            for probe in range where probe + headerSize <= bytes.count {
                guard let frame = intactFrame(in: bytes, at: probe, after: committed, maxRecordSize: maxRecordSize),
                      !batchStart || !frame.joined else { continue }
                let sequence = frame.record.sequence
                let lost = sequence > baseline + 1 ? Int(clamping: sequence - baseline - 1) : 0
                if lost <= (probe - damageStart) / headerSize { return (probe, lost, baseline) }
            }
            return nil
        }

        while offset < bytes.count {
            if let limit = salvageUntil, offset >= limit { salvageUntil = nil }
            let previous = batch.last?.sequence ?? committed
            if let frame = intactFrame(in: bytes, at: offset, after: previous, maxRecordSize: maxRecordSize) {
                if salvageUntil != nil {
                    commit([frame.record], end: frame.end)
                    offset = frame.end
                    continue
                }
                if frame.joined == !batch.isEmpty, !frame.joined || frame.record.sequence == previous + 1 {
                    if batch.isEmpty { batchStart = offset }
                    batch.append(frame.record)
                    offset = frame.end
                    if !frame.more {
                        commit(batch, end: offset)
                        batch = []
                    }
                    continue
                }
            }
            // Damage, or the tail. Without a later batch to prove otherwise,
            // it is the tail, and a batch being read goes with it.
            let damageStart = batch.isEmpty ? (damageBeforeBatch?.offset ?? offset) : batchStart
            guard let proof = plausible(in: (offset + 1)...bytes.count, damageStart: damageStart, batchStart: true) else { break }
            // The batch being read was acknowledged: what of it verified stays.
            var stretchStart = damageStart
            if !batch.isEmpty {
                commit(batch, end: offset)
                batch = []
                stretchStart = offset
            } else {
                damageBeforeBatch = nil
            }
            // Resume at the nearest record that verifies, joined or not, up to
            // the batch that proved the damage is in the middle.
            guard let resume = plausible(in: (offset + 1)...proof.offset, damageStart: stretchStart, batchStart: false) else { break }
            damageBeforeBatch = Corruption(
                offset: stretchStart, length: resume.offset - stretchStart, lostRecords: resume.lost,
                firstLostSequence: resume.lost > 0 ? resume.baseline + 1 : nil
            )
            if resume.offset < proof.offset { salvageUntil = proof.offset }
            offset = resume.offset
        }
        return scan
    }

    // MARK: Appending

    /// Appends one record and returns its sequence number, after the record is
    /// on stable storage.
    @discardableResult
    public func append(_ payload: [UInt8]) throws(StoreError) -> UInt64 {
        try append(batch: [payload]).first!
    }

    /// Appends several records with one write and one `fullSync` (group
    /// commit): the cost of durability is paid once for the batch. Either all
    /// of them are durable when this returns, or the call threw and, after
    /// recovery, all of them or none are there: the records of a batch are
    /// framed together, and a batch a crash kept only part of is dropped
    /// whole at open.
    ///
    /// A batch of more than one record is written in a form releases before
    /// this one cannot read (they see a torn tail); a single record is not.
    ///
    /// - Returns: The sequence numbers assigned, in order.
    @discardableResult
    public func append(batch payloads: [[UInt8]]) throws(StoreError) -> [UInt64] {
        guard !payloads.isEmpty else { return [] }
        try validate(payloads)
        return try state.withLock { (state) throws(StoreError) -> [UInt64] in
            let file = try ready(&state)
            return try write(payloads, to: file, state: &state)
        }
    }

    /// Appends the records `build` returns, as ``append(batch:)`` does, but
    /// tells `build` the sequence number the first of them will be given.
    ///
    /// For a layer that binds a record to its place in the log (a sealed
    /// journal authenticates the sequence along with the payload) and so
    /// cannot build the record until the number is known. `build` runs under
    /// the journal's lock, after it has checked the journal is usable and
    /// before anything is written, so no other append can take the number it
    /// was told; it must not call back into this journal, and it should be
    /// quick. The records it returns are numbered `firstSequence`,
    /// `firstSequence + 1`, and so on. If it returns none, nothing is
    /// written and this returns `[]`: that is how it declines.
    @discardableResult
    public func append(building build: (_ firstSequence: UInt64) -> [[UInt8]]) throws(StoreError) -> [UInt64] {
        try state.withLock { (state) throws(StoreError) -> [UInt64] in
            let file = try ready(&state)
            let payloads = build(state.lastSequence + 1)
            guard !payloads.isEmpty else { return [] }
            try validate(payloads)
            return try write(payloads, to: file, state: &state)
        }
    }

    private func validate(_ payloads: [[UInt8]]) throws(StoreError) {
        let limit = min(options.maxRecordSize, Self.largestPayload)
        for payload in payloads where payload.count > limit {
            throw StoreError(kind: .invalidArgument, operation: "append", path: path, detail: "record of \(payload.count) bytes exceeds \(limit)")
        }
    }

    /// Frames, writes and syncs `payloads` (not empty, already validated) at
    /// the journal's end, under its lock.
    private func write(_ payloads: [[UInt8]], to file: OpenFile, state: inout State) throws(StoreError) -> [UInt64] {
        var bytes: [UInt8] = []
        var sequences: [UInt64] = []
        for (index, payload) in payloads.enumerated() {
            sequences.append(state.lastSequence + UInt64(sequences.count) + 1)
            bytes.append(contentsOf: Journal.frame(
                payload, sequence: sequences.last!, more: index < payloads.count - 1, joined: index > 0
            ))
        }
        do throws(StoreError) {
            try fileSystem.write(file, bytes, at: state.end)
        } catch {
            rollBack(file, to: state.end, state: &state)
            throw error
        }
        do throws(StoreError) {
            try fileSystem.fullSync(file)
        } catch {
            state.poison = StoreError(kind: .poisoned, operation: "append", path: path, detail: "fullSync failed (\(error)); reopen to learn what survived")
            throw error
        }
        state.end += bytes.count
        state.lastSequence = sequences.last!
        return sequences
    }

    /// Undoes a failed write. If even that fails, the journal's end is unknown.
    private func rollBack(_ file: OpenFile, to end: Int, state: inout State) {
        do throws(StoreError) {
            try fileSystem.truncate(file, to: end)
        } catch {
            state.poison = StoreError(kind: .poisoned, operation: "append", path: path, detail: "a failed write could not be rolled back (\(error)); reopen")
        }
    }

    private func ready(_ state: inout State) throws(StoreError) -> OpenFile {
        if let poison = state.poison { throw poison }
        guard let file = state.file else {
            throw StoreError(kind: .invalidArgument, operation: "journal", path: path, detail: "closed")
        }
        return file
    }

    // MARK: Reading

    /// The snapshot and every record after it, read back from the file.
    ///
    /// - Throws: `.corrupt` if the file no longer verifies: it was damaged
    ///   after it was opened. (Damage from a crash is repaired at open.)
    public func replay() throws(StoreError) -> Replay {
        try state.withLock { (state) throws(StoreError) -> Replay in
            let file = try ready(&state)
            return try replay(file, state: state)
        }
    }

    private func replay(_ file: OpenFile, state: State) throws(StoreError) -> Replay {
        let bytes = try fileSystem.read(file, at: 0, count: state.end)
        let through = state.snapshot?.through ?? 0
        let scan = Journal.scan(bytes, maxRecordSize: options.maxRecordSize, after: through)
        // What open found and skipped is known and reported; anything else is
        // damage that appeared since.
        guard scan.validEnd == state.end, scan.corruption == state.corruption else {
            let first = scan.corruption.first { !state.corruption.contains($0) }
            throw StoreError(
                kind: .corrupt, operation: "replay", path: path,
                detail: "record at byte \(first?.offset ?? scan.validEnd) fails verification"
            )
        }
        return Replay(snapshot: state.snapshot, records: scan.records.filter { $0.sequence > through })
    }

    /// The highest sequence number assigned so far (0 if none).
    public var lastSequence: UInt64 { state.withLock { $0.lastSequence } }

    /// The size of the log file in bytes; a signal for when to compact.
    public var byteCount: Int { state.withLock { $0.end } }

    // MARK: Compacting

    /// Replaces the log with a snapshot. `fold` receives the current replay
    /// (snapshot and records) and returns the bytes of the new snapshot; it
    /// runs under the journal's lock, so no append can slip in between the
    /// state it sees and the sequence it is recorded against.
    public func compact(_ fold: (Replay) -> [UInt8]) throws(StoreError) {
        try compact(withSequence: { replay, _ in fold(replay) })
    }

    /// ``compact(_:)``, telling `fold` the sequence the snapshot will be
    /// recorded against (`through`: the journal's last sequence).
    ///
    /// For a layer that binds a snapshot to the sequence it covers, and so
    /// needs the number when it builds the snapshot: this is the journal's own,
    /// read under the lock the fold runs in. `fold` must not call back into
    /// this journal.
    public func compact(withSequence fold: (_ replay: Replay, _ through: UInt64) -> [UInt8]) throws(StoreError) {
        try state.withLock { (state) throws(StoreError) in
            let file = try ready(&state)
            let current = try replay(file, state: state)
            let through = state.lastSequence
            let bytes = fold(current, through)
            // The truncation below destroys the damaged bytes; keep a copy of
            // the log first, so what could not be read is at least not gone.
            let saved = state.corruption.isEmpty ? nil : try saveDamagedLog(file, end: state.end)
            try AtomicFile(fileSystem: fileSystem).write(littleEndian(through) + bytes, to: snapshotPath)
            state.snapshot = Snapshot(through: through, bytes: bytes)
            do throws(StoreError) {
                try fileSystem.truncate(file, to: 0)
                try fileSystem.fullSync(file)
            } catch {
                // The snapshot is durable and covers every record, so the log
                // is merely stale; but whether the truncation reached the disk
                // is unknown.
                state.poison = StoreError(kind: .poisoned, operation: "compact", path: path, detail: "truncating the log failed (\(error)); reopen")
                throw error
            }
            state.end = 0
            state.corruption = []
            var fields: [Event.Field] = [
                .init("path", .string(path)), .init("records", .int(current.records.count)),
                .init("snapshotBytes", .int(bytes.count)),
            ]
            if let saved { fields.append(.init("damagedLogSavedAs", .string(saved))) }
            StoreEvents.record(Event("store.journal_compacted", level: .info, fields: fields))
        }
    }

    /// Writes the log as it stands, damage and all, to `<path>.corrupt-N`
    /// (the next free N), durably, and returns where.
    private func saveDamagedLog(_ file: OpenFile, end: Int) throws(StoreError) -> String {
        let contents = try fileSystem.read(file, at: 0, count: end)
        let directory = StorePath.directory(of: path)
        let prefix = StorePath.name(of: path) + ".corrupt-"
        let taken = try fileSystem.list(directory: directory).compactMap { name -> Int? in
            name.hasPrefix(prefix) ? Int(name.dropFirst(prefix.count)) : nil
        }
        let target = StorePath.join(directory, prefix + String((taken.max() ?? 0) + 1))
        try AtomicFile(fileSystem: fileSystem, options: .init(envelope: false)).write(contents, to: target)
        return target
    }

    /// Replaces the log with `snapshot`, which the caller guarantees folds in
    /// every record appended so far (and the previous snapshot).
    public func compact(snapshot: [UInt8]) throws(StoreError) {
        try compact { _ in snapshot }
    }

    /// Releases the file, and the cross-process lock if it holds one.
    /// Further calls throw.
    public func close() throws(StoreError) {
        try state.withLock { (state) throws(StoreError) in
            guard let file = state.file else { return }
            state.file = nil
            do throws(StoreError) {
                try fileSystem.close(file)
            } catch {
                do throws(StoreError) {
                    try lock?.release()
                } catch {}
                throw error
            }
            try lock?.release()
        }
    }
}
