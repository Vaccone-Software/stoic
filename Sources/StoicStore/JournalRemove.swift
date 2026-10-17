internal import Stoic
internal import Synchronization

/// The journals this process has open, so that a removal can refuse one.
///
/// A journal is identified by the path it was opened with and the file
/// system it was opened through (by object identity, when the file system is a
/// class: `PosixFileSystem` and `SimulatedFileSystem` are; a file system that
/// is a value type has no identity, and all of them share one). It is a
/// best effort, as the removal's documentation says: a second spelling of the
/// same path, or a second `PosixFileSystem()` instance over the same disk, is
/// a different key, and what catches those is the cross-process lock.
struct JournalIdentity: Hashable, Sendable {
    let system: ObjectIdentifier?
    let path: String

    init(path: String, fileSystem: any FileSystem) {
        self.path = path
        system = type(of: fileSystem) is AnyClass ? ObjectIdentifier(fileSystem as AnyObject) : nil
    }
}

/// One open journal's entry in the registry, released by `close()` or, failing
/// that, when the journal goes.
final class JournalRegistration: Sendable {
    private static let table = Mutex<[JournalIdentity: Int]>([:])

    private let identity: JournalIdentity
    private let released = Atomic<Bool>(false)

    init(_ identity: JournalIdentity) {
        self.identity = identity
        Self.table.withLock { $0[identity, default: 0] += 1 }
    }

    deinit { release() }

    func release() {
        guard !released.exchange(true, ordering: .acquiringAndReleasing) else { return }
        Self.table.withLock { table in
            let remaining = (table[identity] ?? 1) - 1
            table[identity] = remaining > 0 ? remaining : nil
        }
    }

    static func isOpen(_ identity: JournalIdentity) -> Bool {
        table.withLock { $0[identity] != nil }
    }
}

extension Journal {
    /// Removes the journal at `path` and everything the store keeps for it:
    /// the log, its `.snapshot`, a `.snapshot-lost` tombstone, the `.lock`
    /// file, every `.corrupt-N` (the log's, and the snapshot's), and the
    /// `.tmp` of the snapshot, the tombstone or a `.corrupt-N` that a crash left.
    ///
    ///     try Journal.remove(at: dir + "/clips.log")      // the whole family, or nothing is left of it
    ///
    /// Nothing else in the directory is touched: a name is removed only if it
    /// is exactly one of those, so `clips.log.bak`, `clips.log2` and
    /// `clips.logbook` stay. (A caller that deletes "everything that starts
    /// with the name" removes what is not the journal's.)
    ///
    /// ## What it refuses
    ///
    /// - **A journal that is open in this process** (opened through this file
    ///   system object at this path, and not closed): `.busy`, and nothing is
    ///   removed. `close()` it first. A journal opened through another
    ///   spelling of the path, or through another file system object, is not
    ///   known to this check.
    /// - **A journal another process holds**, if it opened with
    ///   ``Options/crossProcessLock``: removal takes that lock (and keeps it
    ///   until the last file is gone), so a holder makes it `.busy` too, and a
    ///   writer that opens during the removal waits for it. **A writer that
    ///   does not use the lock cannot be detected**: its open file is
    ///   unlinked under it and its later appends go to a file no one can
    ///   open, so remove a journal another process writes only when that
    ///   process is known to be done with it. A file system with no advisory
    ///   locks skips this check, as `open` does.
    ///
    /// ## What it does not do
    ///
    /// - **It is not atomic.** The log goes first, then the snapshot and the
    ///   rest, the lock file last, and the directory is synced once at the
    ///   end. A crash or a failure between leaves part of the family; call it
    ///   again to finish (it is safe to repeat, and removes nothing twice).
    ///   Until it has finished, opening the path can show what the surviving
    ///   files still hold: a snapshot with no log is a consistent earlier
    ///   state, which is why the log goes first.
    /// - **It does not erase.** On APFS and SSDs the blocks stay until the
    ///   system reuses them, and in any backup made before. A sealed journal
    ///   (design/24) is real deletion only once its keys are retired.
    ///
    /// - Returns: How many files were removed; 0 if there was nothing (and
    ///   then nothing, the lock file included, is created).
    /// - Throws: `.busy` as above; otherwise the `StoreError` of the
    ///   operation that failed, with what had been removed already gone.
    @discardableResult
    public static func remove(at path: String, fileSystem: any FileSystem = PosixFileSystem()) throws(StoreError) -> Int {
        let identity = JournalIdentity(path: path, fileSystem: fileSystem)
        guard !JournalRegistration.isOpen(identity) else {
            throw StoreError(kind: .busy, operation: "remove", path: path, detail: "this journal is open in this process; close it first")
        }
        let directory = StorePath.directory(of: path)
        let family: [String]
        do throws(StoreError) {
            let names = try fileSystem.list(directory: directory)
            family = JournalFamily.members(of: StorePath.name(of: path), in: names)
        } catch where error.kind == .notFound {
            return 0
        }
        guard !family.isEmpty else { return 0 }

        // The lock a writer with `crossProcessLock` holds, taken so that
        // none opens while the files go, and held until the last is gone.
        let lock = FileLock(path: path + ".lock", fileSystem: fileSystem)
        var holding = false
        do throws(StoreError) {
            holding = try lock.tryAcquire()
            guard holding else {
                throw StoreError(kind: .busy, operation: "remove", path: path + ".lock", detail: "another process holds the journal")
            }
        } catch where error.kind == .unsupported {
            // No advisory locks here: neither `open` nor this can use one.
        }

        // Taking the lock made its file if there was none: that one goes too,
        // last, and is not counted among what was removed.
        let lockName = StorePath.name(of: path) + ".lock"
        let doomed = holding && !family.contains(lockName) ? family + [lockName] : family
        let existing = Set(family)
        var removed = 0
        do throws(StoreError) {
            for name in doomed {
                do throws(StoreError) {
                    try fileSystem.remove(StorePath.join(directory, name))
                    if existing.contains(name) { removed += 1 }
                } catch where error.kind == .notFound {
                    // Already gone: another call, or the file system, got there first.
                }
            }
            try fileSystem.syncDirectory(directory)
        } catch {
            if holding { releaseQuietly(lock) }
            throw error
        }
        if holding { try lock.release() }
        StoreEvents.record(Event("store.journal_removed", level: .notice, fields: [
            .init("path", .string(path)), .init("files", .int(removed)),
        ]))
        return removed
    }

    private static func releaseQuietly(_ lock: FileLock) {
        do throws(StoreError) {
            try lock.release()
        } catch {
            // The failure being reported is the one worth reporting; closing the
            // descriptor, which the lock's deinit does anyway, drops the lock.
        }
    }
}

/// Which names in a directory belong to the journal called `name`.
enum JournalFamily {
    /// What follows a journal's own name on a file the journal keeps, and the
    /// order they go in: the log first, then the snapshot and what it
    /// accumulates, the tombstone, the log's damaged copies, the lock last.
    private enum Role: Int, Comparable {
        case log, snapshot, tombstone, damagedLog, lock

        static func < (lhs: Role, rhs: Role) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The names in `directory` that are the journal's, in the order to remove them.
    static func members(of name: String, in directory: [String]) -> [String] {
        var found: [(role: Role, name: String)] = []
        for candidate in directory where candidate.hasPrefix(name) {
            if let role = role(of: candidate.dropFirst(name.count)) { found.append((role, candidate)) }
        }
        return found.sorted { ($0.role, $0.name) < ($1.role, $1.name) }.map(\.name)
    }

    /// `rest` is what follows the journal's name: `""` for the log itself.
    private static func role(of rest: Substring) -> Role? {
        if rest.isEmpty { return .log }
        if rest == ".lock" { return .lock }
        if let damaged = strip(rest, ".corrupt-"), isCorruptCopy(damaged) { return .damagedLog }
        for (suffix, role) in [(".snapshot-lost", Role.tombstone), (".snapshot", .snapshot)] {
            guard let after = strip(rest, suffix) else { continue }
            // The file itself, or the temporary `AtomicFile` writes it through.
            if after.isEmpty || after == ".tmp" { return role }
            if let damaged = strip(after, ".corrupt-"), isCorruptCopy(damaged) { return role }
        }
        return nil
    }

    private static func strip(_ text: Substring, _ prefix: String) -> Substring? {
        text.hasPrefix(prefix) ? text.dropFirst(prefix.count) : nil
    }

    /// `N` or `N.tmp`, N being digits: a quarantined copy and its temporary.
    private static func isCorruptCopy(_ rest: Substring) -> Bool {
        let digits = rest.hasSuffix(".tmp") ? rest.dropLast(4) : rest
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
