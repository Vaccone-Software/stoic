extension Journal {
    /// What a read-only look at a journal found.
    public struct Observation: Sendable, Hashable {
        /// The snapshot and the records after it, as ``Journal/replay()`` would
        /// return them.
        public let replay: Replay
        /// What the scan found. ``Journal/OpenReport/droppedBytes`` is the
        /// length of a torn tail that was *not* cut, because a reader cuts
        /// nothing: it may be a writer's append still in flight.
        public let report: OpenReport
    }

    /// The journal at `path` as a reader sees it, changing nothing on disk:
    /// for a second process (a command-line tool, a helper) that wants the
    /// records a running app is appending.
    ///
    /// ``open(at:fileSystem:options:)`` is for the one writer. It repairs: it
    /// cuts a torn tail, finishes an interrupted compaction, quarantines a
    /// corrupt snapshot, creates the file. A reader that did any of that would
    /// cut the writer's append in flight (a record half written is, to a
    /// reader, a torn tail) and leave the writer's idea of the end of the
    /// file past the real one. This call never opens a file for writing, takes
    /// no lock and creates nothing; it records no event.
    ///
    /// - It reads the **log first, then the snapshot**. A compaction writes
    ///   the new snapshot before it truncates the log, so a log read after the
    ///   truncation means the snapshot read next is already the new one, and a
    ///   log read before it is still complete; reading in the other order
    ///   could pair an old snapshot with a truncated log and lose the records
    ///   between. Whatever it sees is one consistent state of the journal, not
    ///   necessarily the latest.
    /// - A torn tail is ignored and reported (`report.droppedBytes`), never
    ///   cut. A record the writer is still appending is simply not there yet.
    /// - A lost snapshot (a tombstone, or one that fails its checksum) is not
    ///   quarantined: it throws `.corrupt`, as `open` does, unless
    ///   `options.lostSnapshot` is `.acceptLoss`, which reads the records the
    ///   log still holds and says so in `report.lostSnapshot`. The tombstone
    ///   stays: only the writer's `open` clears it.
    /// - `options.middleDamage == .refuse` throws `.corrupt` on damage in the
    ///   middle, as `open` does; `maxRecordSize` is the bound a record is
    ///   checked against. `crossProcessLock` is ignored: a reader never takes
    ///   the writer's lock, which is the point.
    ///
    /// A journal that does not exist reads as empty.
    public static func readOnlyReplay(
        at path: String,
        fileSystem: any FileSystem = PosixFileSystem(),
        options: Options = Options()
    ) throws(StoreError) -> Observation {
        // The log before the snapshot: see above.
        var log: [UInt8] = []
        do throws(StoreError) {
            log = try fileSystem.readAll(path)
        } catch where error.kind == .notFound {
            // Not created yet: an empty log.
        }
        return try observe(log: log, at: path, fileSystem: fileSystem, options: options)
    }

    private static func observe(
        log: [UInt8], at path: String, fileSystem: any FileSystem, options: Options
    ) throws(StoreError) -> Observation {
        let snapshotPath = path + ".snapshot"
        var snapshot: Snapshot?
        var lost = false
        do throws(StoreError) {
            switch Envelope.open(try fileSystem.readAll(snapshotPath)) {
            case .success(let payload):
                guard payload.count >= 8 else {
                    throw StoreError(kind: .corrupt, operation: "snapshot", path: snapshotPath, detail: "too short for a sequence number")
                }
                snapshot = Snapshot(through: readLittleEndian(payload, at: 0), bytes: Array(payload[8...]))
            case .failure:
                lost = true
            }
        } catch where error.kind == .notFound {
            // No snapshot. A writer opening a corrupt one moves it aside only
            // after the tombstone is durable, so the tombstone, checked last,
            // tells that case from a journal that never had one.
        }
        if !lost, try fileSystem.exists(path + lostSnapshotSuffix) { lost = true }
        if lost {
            guard options.lostSnapshot == .acceptLoss else {
                throw StoreError(
                    kind: .corrupt, operation: "snapshot", path: snapshotPath,
                    detail: "the snapshot was lost, and the records it folded in with it; a reader accepts that only with lostSnapshot: .acceptLoss, and the writer's open clears it"
                )
            }
            snapshot = nil
        }

        let through = snapshot?.through ?? 0
        let found = scan(log, maxRecordSize: options.maxRecordSize, after: through)
        if let first = found.corruption.first, options.middleDamage == .refuse {
            throw StoreError(
                kind: .corrupt, operation: "replay", path: path,
                detail: "\(first.length) bytes at offset \(first.offset) fail verification with intact records after them (\(found.corruption.count) such stretches, \(found.corruption.reduce(0) { $0 + $1.lostRecords }) records lost)"
            )
        }
        let records = found.records.filter { $0.sequence > through }
        let report = OpenReport(
            droppedBytes: log.count - found.validEnd, staleRecords: found.records.count - records.count,
            records: records.count, corruption: found.corruption, lostSnapshot: lost
        )
        return Observation(replay: Replay(snapshot: snapshot, records: records), report: report)
    }
}
