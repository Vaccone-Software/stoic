internal import Stoic
internal import StoicJSON
public import StoicSchema
public import StoicStore
internal import Synchronization

/// Why ``SettingsStore/replaceUnusableFile(with:keepingCopyAt:)`` did not replace the file.
extension SettingsStore {
    public enum ReplaceError: Error, Sendable, CustomStringConvertible {
        /// The store is app-owned. Its unusable files are quarantined at open, and
        /// there is no file of a person's to replace.
        case notHandEdited
        /// The file, read again just now, is usable (or missing): the person has
        /// fixed it since the app saw it, or it was never broken. Nothing is
        /// replaced; an ordinary ``SettingsStore/update(_:)`` is the call.
        case fileIsUsable
        /// Another process holds the lock on the file. Nothing was read or
        /// written; trying again is safe.
        case busy
        /// The lock file could not be opened or locked. Nothing was read or written.
        case lockFailed(StoreError)
        /// The replacement is not a value the schema accepts. Nothing was done.
        case invalid([Issue])
        /// The copy's path is taken. A copy is never written over a file, because
        /// that file may be an earlier copy of the person's work. Nothing was done.
        case backupExists(String)
        /// The file could not be copied (it cannot be read, the copy cannot be
        /// written, or what was written is not what was read). The file is
        /// untouched, and a partial copy may remain at the copy's path.
        case copyFailed(StoreError)
        /// The copy was made, at `copy`, and the replacement could not be written:
        /// the file is as it was.
        case storage(StoreError, copy: String)
        /// The copy was made, at `copy`, and the replacement was written and
        /// published, but the disk could not confirm it is durable: a power loss
        /// may bring back the broken file. Like ``SettingsStore/UpdateError/durabilityUnknown(_:)``,
        /// the replacement *happened*.
        case durabilityUnknown(StoreError, copy: String)

        public var description: String {
            switch self {
            case .notHandEdited: "only a hand-edited settings file can be replaced this way"
            case .fileIsUsable: "the settings file can be read: nothing was replaced"
            case .busy: "settings replacement refused: another process is writing the file"
            case .lockFailed(let error): "settings replacement refused: the lock could not be taken: \(error)"
            case .invalid(let issues): "settings replacement refused: " + issues.map(\.description).joined(separator: "; ")
            case .backupExists(let path): "settings replacement refused: \(path) already exists, and a copy is never written over a file"
            case .copyFailed(let error): "the settings file could not be copied, and was left as it is: \(error)"
            case .storage(let error, let copy): "settings could not be written (the file is as it was; a copy is at \(copy)): \(error)"
            case .durabilityUnknown(let error, let copy):
                "settings were replaced (the old file is at \(copy)), but may not survive a power loss: \(error)"
            }
        }
    }

    // MARK: Materializing

    /// Writes the settings file if there is none: the sparse form of the
    /// current value (the defaults, on a first launch) with the file header. If
    /// a file is there, whatever it holds, nothing is read, changed or reported.
    ///
    ///     try settings.materialize()    // first launch: leave the person a file to edit
    ///
    /// A hand-edited store does it under the lock on `<path>.lock`, and looks
    /// for the file again once it holds it, so two processes that start together
    /// write it once: the one that loses the race finds the file there. Like
    /// ``update(_:)`` it does not wait: `.busy` if another holds the lock now.
    /// A file that is there but cannot be used is *present*: this never writes
    /// over it (``replaceUnusableFile(with:keepingCopyAt:)`` does, on purpose).
    ///
    /// - Returns: Whether it wrote the file.
    /// - Throws: ``UpdateError``: `.busy`; `.storage` when it could not write (nothing
    ///   is there); `.durabilityUnknown` when it did, and the disk could not confirm.
    @discardableResult
    public func materialize() throws(UpdateError) -> Bool {
        defer { notifyObservers() }
        let held = format == .handEdited ? try lockWithoutWaiting() : nil
        defer { release(held) }
        return try writing.withLock { _ throws(UpdateError) -> Bool in try materializeLocked() }
    }

    /// ``materialize()``, waiting for another process that holds the lock on a
    /// hand-edited file to let go, **and blocking the calling thread while it
    /// waits**: for a first launch that cannot `await`, which would otherwise
    /// see `.busy` whenever a command-line tool happened to be writing at that
    /// moment, and have to write the retry itself.
    ///
    /// The wait is ``blockingUpdate(waitingUpTo:_:)``'s, with its cautions: real
    /// time, polled every 25 ms, not on the main actor in new code, ended by the
    /// lock being free, by `waitingUpTo` (``UpdateError/busy``, `settings.busy`),
    /// or by cancellation (`CancellationError`, checked between tries), and
    /// nothing is read or written until the lock is held. `.zero` tries once,
    /// as ``materialize()`` does. For an app-owned store there is no other
    /// writer to wait for.
    ///
    /// - Parameters:
    ///   - wait: How long to wait for the lock; the store's
    ///     ``HandEditedOptions/lockTimeout`` when `nil`.
    /// - Returns: Whether it wrote the file.
    /// - Throws: ``UpdateError``, or `CancellationError`.
    @discardableResult
    public func blockingMaterialize(waitingUpTo wait: Duration? = nil) throws -> Bool {
        defer { notifyObservers() }
        let held = format == .handEdited ? try lockBlocking(waitingUpTo: wait ?? editing.lockTimeout) : nil
        defer { release(held) }
        return try writing.withLock { _ throws(UpdateError) -> Bool in try materializeLocked() }
    }

    /// The writing of the file, under `writing` and the lock.
    private func materializeLocked() throws(UpdateError) -> Bool {
        let present: Bool
        do throws(StoreError) {
            present = try file.fileSystem.exists(path)
        } catch {
            throw .storage(error)
        }
        if present { return false }
        // What is held may be older than a deletion made since: adopt that first, as an update does.
        let state = format == .handEdited ? refresh() : current.withLock { $0 }
        let written: Written
        do throws(StoreError) {
            written = try write(state.value, carrying: state.document, repaired: state.repaired)
        } catch where error.kind == .durabilityUnknown {
            let json = encoded(state.value, carrying: state.document, repaired: state.repaired)
            publish(committed(state.value, Written(json: json.json, repaired: json.repaired, bytes: bytes(for: json.json))), cause: .update)
            Ambient.record(Event("settings.save_failed", level: .error, label: path, fields: [
                .init("error", .error(error)), .init("during", .string("materialize"), privacy: .public),
            ]))
            throw .durabilityUnknown(error)
        } catch {
            Ambient.record(Event("settings.save_failed", level: .error, label: path, fields: [
                .init("error", .error(error)), .init("during", .string("materialize"), privacy: .public),
            ]))
            throw .storage(error)
        }
        publish(committed(state.value, written), cause: .update)
        Ambient.record(Event("settings.materialized", level: .info, label: path))
        return true
    }

    // MARK: Replacing an unusable file

    /// Replaces a hand-edited file that cannot be read with `value`, after
    /// copying what the person wrote to a file of its own. For "reset the
    /// configuration" when the file has a typo the app will not write over.
    ///
    ///     do {
    ///         let copy = try settings.replaceUnusableFile(with: Prefs())
    ///         tell("The old file is kept at \(copy)")
    ///     } catch .fileIsUsable { try settings.update { $0 = Prefs() } }
    ///
    /// **It is explicit, and never implicit**: no update, reload or open does
    /// this, and an update of an unusable file still throws
    /// ``UpdateError/fileUnusable(_:)``. The steps, under the lock on `<path>.lock`:
    ///
    /// 1. **Read the file again.** If it can be used now (the person fixed it
    ///    since the app looked), nothing is touched: ``ReplaceError/fileIsUsable``.
    ///    This is a reset of a broken file, not of a good one.
    /// 2. **Check the replacement** against the schema (``ReplaceError/invalid(_:)``).
    /// 3. **Copy the person's bytes** to `keepingCopyAt` or, by default,
    ///    `<path>.broken-N` (N one more than the highest there is, as a
    ///    quarantined file is numbered; there is no wall clock in Stoic's
    ///    ambient, and a number sorts and cannot collide). The copy is written
    ///    atomically, mode `0600`, read back and compared with what was read,
    ///    *before anything is replaced*. A copy path that exists is refused
    ///    (``ReplaceError/backupExists(_:)``): it may be an earlier copy.
    /// 4. **Write `value`** as a new file: sparse, canonical, with the header,
    ///    carrying no unknown keys (a reset keeps nothing of the old document). A
    ///    failure leaves the broken file, and the copy beside it.
    /// 5. **Publish** `value`, and ``fileProblem`` clears.
    ///
    /// Like ``update(_:)`` it does not wait for the lock (`.busy`).
    ///
    /// - Parameters:
    ///   - value: What the file holds afterwards; usually the defaults.
    ///   - copy: Where the person's bytes go (`keepingCopyAt`), in a directory that exists.
    /// - Returns: Where the copy is.
    /// - Throws: ``ReplaceError``.
    @discardableResult
    public func replaceUnusableFile(with value: Value, keepingCopyAt copy: String? = nil) throws(ReplaceError) -> String {
        guard format == .handEdited else { throw .notHandEdited }
        defer { notifyObservers() }
        let held: FileLock?
        do throws(UpdateError) {
            held = try lockWithoutWaiting()
        } catch {
            if case .storage(let failure) = error { throw .lockFailed(failure) }
            throw .busy
        }
        defer { release(held) }
        return try writing.withLock { _ throws(ReplaceError) -> String in
            try replaceLocked(with: value, keepingCopyAt: copy, source: nil)
        }
    }

    /// ``replaceUnusableFile(with:keepingCopyAt:)``, waiting for another process
    /// that holds the lock on the file to let go, **and blocking the calling
    /// thread while it waits**: for a "reset configuration" command that cannot
    /// `await`, and should not answer "try again" because a command-line tool
    /// happened to be writing at that moment.
    ///
    /// The wait is ``blockingUpdate(waitingUpTo:_:)``'s, with its cautions: real
    /// time, polled every 25 ms, not on the main actor in new code, ended by the
    /// lock being free, by `waitingUpTo` (``ReplaceError/busy``, `settings.busy`),
    /// or by cancellation (`CancellationError`, checked between tries), and
    /// nothing is read, copied or written until the lock is held. `.zero` tries
    /// once, as ``replaceUnusableFile(with:keepingCopyAt:)`` does. Every step
    /// after the lock is that call's, with its guarantees: the person's bytes are
    /// copied and checked before anything is replaced.
    ///
    /// - Parameters:
    ///   - value: What the file holds afterwards; usually the defaults.
    ///   - copy: Where the person's bytes go, in a directory that exists.
    ///   - wait: How long to wait for the lock; the store's
    ///     ``HandEditedOptions/lockTimeout`` when `nil`.
    ///   - source: Who is doing it, carried to the ``SettingsChange`` it makes
    ///     (cause ``SettingsChange/Cause/reset``; ``SettingsChange/source``).
    /// - Returns: Where the copy is.
    /// - Throws: ``ReplaceError``, or `CancellationError`.
    @discardableResult
    public func blockingReplaceUnusableFile(
        with value: Value, keepingCopyAt copy: String? = nil, waitingUpTo wait: Duration? = nil, source: String? = nil
    ) throws -> String {
        guard format == .handEdited else { throw ReplaceError.notHandEdited }
        defer { notifyObservers() }
        let held: FileLock?
        do {
            held = try lockBlocking(waitingUpTo: wait ?? editing.lockTimeout)
        } catch UpdateError.storage(let failure) {
            throw ReplaceError.lockFailed(failure)
        } catch UpdateError.busy {
            throw ReplaceError.busy
        }
        defer { release(held) }
        return try writing.withLock { _ throws(ReplaceError) -> String in
            try replaceLocked(with: value, keepingCopyAt: copy, source: source)
        }
    }

    /// The replacement, under `writing` and the lock.
    private func replaceLocked(with value: Value, keepingCopyAt copy: String?, source: String?) throws(ReplaceError) -> String {
        let state = refresh()
        guard state.problem != nil else { throw .fileIsUsable }
        let problems = schema.validate(value)
        guard problems.isEmpty else {
            Ambient.record(Event("settings.rejected", level: .notice, label: path, fields: [.init("issues", .int(problems.count))]))
            throw .invalid(problems)
        }
        let copyPath = try copyBrokenFile(to: copy)
        let written: Written
        do throws(StoreError) {
            written = try write(value, carrying: nil, repaired: [])
        } catch where error.kind == .durabilityUnknown {
            let json = encoded(value, carrying: nil, repaired: [])
            publish(committed(value, Written(json: json.json, repaired: json.repaired, bytes: bytes(for: json.json))), cause: .reset, source: source)
            Ambient.record(Event("settings.save_failed", level: .error, label: path, fields: [
                .init("error", .error(error)), .init("during", .string("replace"), privacy: .public),
            ]))
            throw .durabilityUnknown(error, copy: copyPath)
        } catch {
            Ambient.record(Event("settings.save_failed", level: .error, label: path, fields: [
                .init("error", .error(error)), .init("during", .string("replace"), privacy: .public),
            ]))
            throw .storage(error, copy: copyPath)
        }
        publish(committed(value, written), cause: .reset, source: source)
        Ambient.record(Event("settings.replaced", level: .warning, label: path, fields: [
            .init("copy", .string(copyPath)),
        ]))
        return copyPath
    }

    /// Copies the file's bytes to `requested` (or the next free `<path>.broken-N`),
    /// and checks the copy: the step before anything is replaced.
    private func copyBrokenFile(to requested: String?) throws(ReplaceError) -> String {
        let contents: AtomicFile.Contents?
        do throws(StoreError) {
            contents = try file.read(path)
        } catch {
            throw .copyFailed(error)
        }
        // Gone since the lock was taken (an editor does not take it): nothing left to keep.
        guard let bytes = contents?.bytes else { throw .fileIsUsable }
        let target: String
        do throws(StoreError) {
            if let requested {
                target = requested
            } else {
                target = try nextBrokenPath()
            }
        } catch {
            throw .copyFailed(error)
        }
        if requested != nil {
            let taken: Bool
            do throws(StoreError) {
                taken = try file.fileSystem.exists(target)
            } catch {
                throw .copyFailed(error)
            }
            guard !taken else { throw .backupExists(target) }
        }
        do throws(StoreError) {
            try AtomicFile(fileSystem: file.fileSystem, options: .init(envelope: false, newFileMode: 0o600)).write(bytes, to: target)
            guard try file.fileSystem.readAll(target) == bytes else {
                throw StoreError(kind: .corrupt, operation: "copy", path: target, detail: "the copy does not hold what was read")
            }
        } catch {
            throw .copyFailed(error)
        }
        return target
    }

    /// `<path>.broken-N` with N one more than the highest beside the file.
    private func nextBrokenPath() throws(StoreError) -> String {
        let slash = path.lastIndex(of: "/")
        let directory = slash.map { $0 == path.startIndex ? "/" : String(path[..<$0]) } ?? "."
        let name = slash.map { String(path[path.index(after: $0)...]) } ?? path
        let prefix = name + ".broken-"
        let highest = try file.fileSystem.list(directory: directory)
            .compactMap { $0.hasPrefix(prefix) ? Int($0.dropFirst(prefix.count)) : nil }
            .max() ?? 0
        let next = prefix + String(highest + 1)
        return directory == "." ? next : (directory.hasSuffix("/") ? directory + next : directory + "/" + next)
    }
}
