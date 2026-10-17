#if STOIC_CRYPTO
internal import Stoic
public import StoicStore
internal import Synchronization

/// A `Journal` whose every record and snapshot is sealed.
///
///     let log = try SealedJournal.open(at: dir + "/clips.log", context: SealContext("app.clips", "main"), keyring: ring)
///     try log.append(batch: [record1, record2])               // sealed, then durable
///
///     let replay = try log.replay()                           // after a relaunch
///     for record in replay.records { apply(record.bytes) }    // plaintext
///     for failure in replay.failures { … }                    // what could not be opened, and why
///
///     try log.compact(rotatingKey: true, snapshot: encode(state))   // and now the old records are gone
///
/// The journal underneath does what it always does (framing, checksums, a torn
/// tail cut at open, group commit, crash-safe compaction, design/15); what it
/// stores is ``Sealing`` output. A record's context is the journal's
/// (``SealContext``) plus its **sequence number**, a snapshot's is the journal's
/// plus the sequence it covers, and each in its own domain, so a record
/// cannot be opened as a snapshot, at another position, or in another journal.
///
/// ## What is sealed to what
///
/// - **Reordering and duplication fail.** Swap two records' bytes, copy one to
///   another position, or repeat one: each fails to open (``SealError/tampered``),
///   because its sequence number is authenticated. The journal assigns the
///   sequence under its own lock and tells `Journal/append(building:)` its
///   first, so a record is sealed knowing its number; nothing here predicts it.
/// - **Deletion is not detected.** Dropping the *last* records of a log, or
///   replacing the whole directory with an older copy of it, leaves a valid
///   journal: there is no chain from a record to the one before, and no counter
///   outside the files. An attacker who can write the files can roll them back.
///   Sealing keeps data private and unforgeable; it does not make a log
///   append-only against someone with write access.
/// - **Failures are per record.** A record that fails to open is reported with
///   its sequence and kind (``SealError/tampered``, ``SealError/unknownKey(_:)``,
///   ``SealError/notSealed``) in ``Replay/failures``, and does not hide the
///   others. A torn tail is the journal's own business: it is cut at open and
///   reported in ``Replay/report``.
///
/// ## Rotation, and making a deletion real
///
/// ``compact(rotatingKey:unreadable:_:)`` with `rotatingKey: true` is how a
/// deleted record stops existing. It
///
/// 1. rotates the keyring (the new key is persisted before it is used),
/// 2. folds the state into a snapshot sealed **under the new key** and makes it
///    durable (the journal's atomic snapshot, then truncating the log), and only
///    then
/// 3. retires every key that existed before step 1.
///
/// Every record written before the compaction, and the old snapshot, are then
/// ciphertext under keys that exist nowhere. The order is the safety: a crash
/// before step 3 leaves a ring that still opens everything; a crash before the
/// snapshot is durable leaves the old log and the old keys. The old bytes stay
/// on the disk (APFS and SSDs do not erase them) and in any backup, and are
/// noise without the key. **The keyring must be this journal's alone** (or
/// shared only with things that are folded in the same way): retiring a key
/// destroys everything any other file sealed under it. A backup of the
/// *custody* made before the retirement still holds the old keys, and with a
/// backup of the files, the old records (design/24).
///
/// ## Two processes
///
/// One process writes (the app); another may read with
/// ``readOnlyReplay(at:context:keyring:fileSystem:options:)``, which changes
/// nothing on disk. `Journal/Options/crossProcessLock` keeps a second
/// *writer* out. A reader whose keyring is older than the writer's rotation
/// reports ``SealError/unknownKey(_:)`` for what was sealed under the new key;
/// ``Keyring/reload()`` and read again.
///
/// ## Cost
///
/// Each record is sealed on its own: ``Sealing/overhead`` bytes plus the
/// journal's 16-byte frame, about 90 bytes around a 24-byte record, and a seal
/// and an open per record. For a log of many small records that is storage and
/// microseconds, not a hazard; pack records that always travel together into
/// one `append`, which is one record. `Journal.Options.maxRecordSize` bounds the
/// *sealed* record, so a plaintext may be at most ``Sealing/overhead`` bytes
/// smaller than it; a larger one is `.store(.invalidArgument)` and nothing is
/// written.
public final class SealedJournal: Sendable {
    /// What a compaction does about records it cannot open.
    public enum Unreadable: Sendable, Hashable {
        /// Throw ``SealedStoreError/unreadable(count:)`` and write nothing:
        /// a snapshot built from what could be read would destroy what could not.
        case refuse
        /// Compact anyway; the unreadable values are gone, and counted in the
        /// `sealed.journal_compacted` event. The caller has accepted the loss.
        case discard
    }

    /// Everything needed to rebuild state, opened: the snapshot, the records
    /// after it, and what could not be opened.
    public struct Replay: Sendable, Hashable {
        public struct Record: Sendable, Hashable {
            public let sequence: UInt64
            /// The plaintext.
            public let bytes: [UInt8]
        }

        public struct Snapshot: Sendable, Hashable {
            /// The last sequence the snapshot covers.
            public let through: UInt64
            /// The plaintext.
            public let bytes: [UInt8]
        }

        /// A value that could not be opened.
        public struct Failure: Sendable, Hashable {
            public enum Item: Sendable, Hashable {
                case record(sequence: UInt64)
                case snapshot(through: UInt64)
            }

            public let item: Item
            public let error: SealError
        }

        public let snapshot: Snapshot?
        /// The records that opened, in order.
        public let records: [Record]
        /// The snapshot and records that did not, with the reason: tampered, an
        /// unknown key, not sealed. The ones that opened are in `snapshot` and
        /// `records` all the same.
        public let failures: [Failure]
        /// What the journal found when it was opened: a torn tail it cut, damage
        /// in the middle it skipped (design/15). For a read-only replay, what the
        /// look found, with nothing cut.
        public let report: Journal.OpenReport

        /// Whether everything in the journal opened.
        public var isComplete: Bool { failures.isEmpty }
    }

    public let path: String
    public let context: SealContext
    public let keyring: Keyring

    private let journal: Journal
    /// Serialises compactions: a rotation and what follows it must not be
    /// interleaved with another's.
    private let maintenance = Mutex<Void>(())

    private init(path: String, context: SealContext, keyring: Keyring, journal: Journal) {
        self.path = path
        self.context = context
        self.keyring = keyring
        self.journal = journal
    }

    // MARK: Opening

    /// Opens the journal at `path`, repairing a torn tail as `Journal` does,
    /// for the one process that writes it.
    ///
    /// Nothing is opened (decrypted) here: an unknown key is found by
    /// ``replay()``, not by `open`, so a journal whose key is lost can still be
    /// opened, inspected and compacted away.
    ///
    /// - Parameters:
    ///   - context: What the journal is for, and which one it is (a purpose and
    ///     the journal's logical name). Authenticated with every record; keep
    ///     it the same for the journal's life.
    ///   - keyring: Its keys. Records are sealed under the current key.
    ///   - options: The journal's, including `crossProcessLock`.
    public static func open(
        at path: String,
        context: SealContext,
        keyring: Keyring,
        fileSystem: any FileSystem = PosixFileSystem(),
        options: Journal.Options = Journal.Options()
    ) throws(SealedStoreError) -> SealedJournal {
        do throws(StoreError) {
            let journal = try Journal.open(at: path, fileSystem: fileSystem, options: options)
            return SealedJournal(path: path, context: context, keyring: keyring, journal: journal)
        } catch {
            throw .store(error)
        }
    }

    /// What opening found and repaired.
    public var openReport: Journal.OpenReport { journal.openReport }

    /// The highest sequence number assigned so far (0 if none).
    public var lastSequence: UInt64 { journal.lastSequence }

    /// The size of the log file in bytes; a signal for when to compact.
    public var byteCount: Int { journal.byteCount }

    // MARK: Appending

    /// Seals `plaintext` and appends it; returns its sequence number once the
    /// record is on stable storage.
    @discardableResult
    public func append(_ plaintext: [UInt8]) throws(SealedStoreError) -> UInt64 {
        try append(batch: [plaintext]).first ?? 0
    }

    /// Seals each record and appends them as `Journal/append(batch:)` does:
    /// one write and one `fullSync`, all of them or, after a crash, none.
    ///
    /// The key is read, and each record sealed, *inside* the journal's lock,
    /// where the sequence it will carry is known and no compaction can have
    /// retired the key between choosing it and writing the record.
    ///
    /// - Returns: The sequence numbers, in order.
    @discardableResult
    public func append(batch plaintexts: [[UInt8]]) throws(SealedStoreError) -> [UInt64] {
        guard !plaintexts.isEmpty else { return [] }
        var failure: SealedStoreError?
        let sequences: [UInt64]
        do throws(StoreError) {
            sequences = try journal.append(building: { first in
                let key: SealingKey
                do throws(KeyringError) {
                    key = try keyring.current
                } catch {
                    failure = .keyring(error)
                    return []
                }
                var sealed: [[UInt8]] = []
                sealed.reserveCapacity(plaintexts.count)
                for (index, plaintext) in plaintexts.enumerated() {
                    let recordContext = context.deriving(.journalRecord, number: first + UInt64(index))
                    do throws(SealError) {
                        sealed.append(try Sealing.seal(plaintext, context: recordContext, key: key))
                    } catch {
                        failure = .seal(error)
                        return []
                    }
                }
                return sealed
            })
        } catch {
            throw .store(error)
        }
        if let failure { throw failure }
        return sequences
    }

    // MARK: Reading

    /// The snapshot and every record after it, opened.
    ///
    /// A value that fails to open is in ``Replay/failures`` and the rest are
    /// returned; when any fail, a `sealed.records_unreadable` event says how
    /// many, by kind.
    ///
    /// - Throws: `.store(.corrupt)` if the file no longer verifies: it was
    ///   damaged after it was opened (reopen to resynchronise).
    public func replay() throws(SealedStoreError) -> Replay {
        let raw: Journal.Replay
        do throws(StoreError) {
            raw = try journal.replay()
        } catch {
            throw .store(error)
        }
        let replay = Self.opened(raw, report: journal.openReport, context: context, keyring: keyring)
        Self.reportUnreadable(replay, context: context)
        return replay
    }

    /// The journal at `path` as a second process sees it, opened, changing
    /// nothing on disk (`Journal/readOnlyReplay(at:fileSystem:options:)`): no
    /// repair, no lock, no file created, a torn tail ignored and reported.
    ///
    /// What it returns is one consistent state of the journal, not necessarily
    /// the latest. A keyring older than the writer's last rotation cannot open
    /// what was sealed after it: reload the keyring and read again.
    public static func readOnlyReplay(
        at path: String,
        context: SealContext,
        keyring: Keyring,
        fileSystem: any FileSystem = PosixFileSystem(),
        options: Journal.Options = Journal.Options()
    ) throws(SealedStoreError) -> Replay {
        let seen: Journal.Observation
        do throws(StoreError) {
            seen = try Journal.readOnlyReplay(at: path, fileSystem: fileSystem, options: options)
        } catch {
            throw .store(error)
        }
        let replay = opened(seen.replay, report: seen.report, context: context, keyring: keyring)
        reportUnreadable(replay, context: context)
        return replay
    }

    private static func snapshotContext(_ context: SealContext, through: UInt64) -> SealContext {
        context.deriving(.journalSnapshot, number: through)
    }

    /// Opens what the journal returned. Pure: no event, no I/O.
    private static func opened(_ raw: Journal.Replay, report: Journal.OpenReport, context: SealContext, keyring: Keyring) -> Replay {
        var failures: [Replay.Failure] = []
        var snapshot: Replay.Snapshot?
        if let stored = raw.snapshot {
            do throws(SealError) {
                let bytes = try Sealing.open(stored.bytes, context: snapshotContext(context, through: stored.through), keyring: keyring)
                snapshot = Replay.Snapshot(through: stored.through, bytes: bytes)
            } catch {
                failures.append(.init(item: .snapshot(through: stored.through), error: error))
            }
        }
        var records: [Replay.Record] = []
        records.reserveCapacity(raw.records.count)
        for stored in raw.records {
            do throws(SealError) {
                let bytes = try Sealing.open(
                    stored.bytes, context: context.deriving(.journalRecord, number: stored.sequence), keyring: keyring
                )
                records.append(Replay.Record(sequence: stored.sequence, bytes: bytes))
            } catch {
                failures.append(.init(item: .record(sequence: stored.sequence), error: error))
            }
        }
        return Replay(snapshot: snapshot, records: records, failures: failures, report: report)
    }

    private static func reportUnreadable(_ replay: Replay, context: SealContext) {
        guard !replay.failures.isEmpty else { return }
        var tampered = 0, unknownKey = 0, notSealed = 0, other = 0
        for failure in replay.failures {
            switch failure.error {
            case .tampered: tampered += 1
            case .unknownKey: unknownKey += 1
            case .notSealed: notSealed += 1
            case .torn, .unsupportedFormat, .encryptionFailed: other += 1
            }
        }
        let snapshotLost = replay.failures.contains { if case .snapshot = $0.item { true } else { false } }
        SealedEvents.record(Event("sealed.records_unreadable", level: .error, fields: [
            .init("purpose", .string(context.purpose)), .init("unreadable", .int(replay.failures.count)),
            .init("tampered", .int(tampered)), .init("unknownKey", .int(unknownKey)),
            .init("notSealed", .int(notSealed)), .init("other", .int(other)), .init("snapshot", .bool(snapshotLost)),
        ]))
    }

    // MARK: Compacting

    /// Replaces the log with a snapshot sealed under the current key, folding
    /// the state with `fold`, which is given the opened replay.
    ///
    /// With `rotatingKey`, the keys that existed when this began are retired
    /// once the snapshot is durable, so that **everything written before is
    /// unreadable for ever** (see the type's note on rotation, and that the
    /// keyring must be this journal's own).
    ///
    /// `fold` runs under the journal's lock, as `Journal/compact(_:)`'s does:
    /// no append can slip between the state it sees and the sequence the
    /// snapshot covers. It must not call back into this journal.
    ///
    /// - Parameter unreadable: What to do if any record, or the snapshot,
    ///   cannot be opened: refuse, by default (`fold` is not called and
    ///   nothing is written), because the snapshot cannot contain what could
    ///   not be read.
    /// - Throws: ``SealedStoreError``. ``SealedStoreError/compactedButNotShredded(_:)``
    ///   means the compaction itself *succeeded* and only the retirement of the
    ///   old keys failed. Any other error, from before the snapshot is
    ///   durable, leaves the journal as it was (a rotation, if one happened,
    ///   stays: a new key that sealed nothing is harmless).
    public func compact(
        rotatingKey: Bool = false,
        unreadable: Unreadable = .refuse,
        _ fold: (Replay) -> [UInt8]
    ) throws(SealedStoreError) {
        try maintenance.withLock { (_) throws(SealedStoreError) in
            let before = keyring.keyIDs
            if rotatingKey {
                do throws(KeyringError) {
                    try keyring.rotate()
                } catch {
                    throw .keyring(error)
                }
            }

            enum Outcome {
                case undecided
                case refused(Int)
                case failed(SealedStoreError)
                case folded(records: Int, discarded: Int)
            }
            var outcome = Outcome.undecided
            do throws(StoreError) {
                try journal.compact(withSequence: { raw, through in
                    let replay = Self.opened(raw, report: journal.openReport, context: context, keyring: keyring)
                    if unreadable == .refuse, !replay.failures.isEmpty {
                        outcome = .refused(replay.failures.count)
                        return nil
                    }
                    let plaintext = fold(replay)
                    let key: SealingKey
                    do throws(KeyringError) {
                        key = try keyring.current
                    } catch {
                        outcome = .failed(.keyring(error))
                        return nil
                    }
                    do throws(SealError) {
                        let sealed = try Sealing.seal(plaintext, context: Self.snapshotContext(context, through: through), key: key)
                        outcome = .folded(records: replay.records.count, discarded: replay.failures.count)
                        return sealed
                    } catch {
                        outcome = .failed(.seal(error))
                        return nil
                    }
                })
            } catch {
                throw .store(error)
            }
            let folded: (records: Int, discarded: Int)
            switch outcome {
            case .refused(let count): throw .unreadable(count: count)
            case .failed(let error): throw error
            case .undecided: return
            case .folded(let records, let discarded): folded = (records, discarded)
            }

            // The snapshot is durable under the current key and the log is
            // empty. Only now can the old keys go.
            var retired = 0
            if rotatingKey {
                do throws(KeyringError) {
                    retired = try keyring.retire(ids: before)
                } catch {
                    SealedEvents.record(Event("sealed.shred_incomplete", level: .error, fields: [
                        .init("purpose", .string(context.purpose)), .init("keys", .int(before.count)),
                    ]))
                    throw .compactedButNotShredded(error)
                }
            }
            SealedEvents.record(Event("sealed.journal_compacted", level: .info, fields: [
                .init("purpose", .string(context.purpose)), .init("records", .int(folded.records)),
                .init("rotated", .bool(rotatingKey)), .init("retiredKeys", .int(retired)),
                .init("discarded", .int(folded.discarded)),
            ]))
        }
    }

    /// ``compact(rotatingKey:unreadable:_:)`` with a snapshot the caller has
    /// already built, which must fold in every record appended so far and the
    /// previous snapshot (`replay()` gives them).
    public func compact(snapshot: [UInt8], rotatingKey: Bool = false, unreadable: Unreadable = .refuse) throws(SealedStoreError) {
        try compact(rotatingKey: rotatingKey, unreadable: unreadable) { _ in snapshot }
    }

    /// Releases the file, and the cross-process lock if the journal holds one.
    /// Further calls throw.
    public func close() throws(SealedStoreError) {
        do throws(StoreError) {
            try journal.close()
        } catch {
            throw .store(error)
        }
    }
}
#endif
