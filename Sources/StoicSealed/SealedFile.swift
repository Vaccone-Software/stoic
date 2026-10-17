#if STOIC_CRYPTO
internal import Stoic
public import StoicStore

/// A whole file, sealed: `AtomicFile`'s crash-safe write, around bytes
/// that are AES-256-GCM ciphertext.
///
///     let notes = SealedFile(keyring: ring)
///     try notes.write(data, to: path, context: SealContext("app.notes", id))
///     let data = try notes.read(path, context: SealContext("app.notes", id))   // nil if there is no file
///
/// The file holds exactly what ``Sealing/seal(_:context:key:)`` made, with no
/// checksum envelope on top: the tag authenticates every byte, and an
/// envelope's CRC would only turn a tampered file into a "corrupt" one and
/// invite `AtomicFile` to quarantine it.
///
/// ## Contract
///
/// - **Whole-file and atomic.** Every ``write(_:to:context:)`` is an
///   `AtomicFile.write`: after a crash, or an error, `read` finds the old
///   value or the new one in full, never a torn file, and never plaintext:
///   nothing the store writes (the temporary, a previous generation) is
///   anything but a sealed value, and checked at every crash point.
/// - **Private by default.** A new file is created `0o600`
///   (``Options/newFileMode``) with its mode set before a byte is written;
///   a replacement keeps the mode of the file it replaces, as `AtomicFile`
///   does. Sealing makes the contents safe at any mode; the mode keeps the file's
///   existence, size and times from other users.
/// - **A previous generation is sealed too.** With ``Options/keepPrevious`` the
///   old file is kept as `<path>.previous`: it is a sealed value, under the key
///   that sealed it. `read` falls back to it only when the current file is
///   missing (the instant a crash can leave between demoting the old file and
///   renaming the new). A file that is *there* and fails to open is reported,
///   never quietly replaced by an older one: an older value is not "the same
///   data".
/// - **Failures are told apart** (``SealedStoreError``): ``SealError/notSealed``
///   for a plaintext file, ``SealError/tampered``, ``SealError/torn``,
///   ``SealError/unknownKey(_:)`` for a key that is gone. None is quarantined,
///   renamed or removed: the file is left as it is for the app to decide.
/// - **Plaintext is adopted, not assumed.** ``adopt(path:context:)`` seals an
///   existing plaintext file in place, **proving the sealed copy opens to the
///   plaintext before it replaces it**, and removes every plaintext copy the
///   store itself keeps. It cannot erase the blocks the old file occupied
///   (below).
///
/// ## What deleting a file does not do
///
/// On APFS and on SSDs, replacing or removing a file does not erase the blocks
/// it occupied: the old plaintext may remain on the device until the system
/// reuses them, and in snapshots and backups made before. Adopting a plaintext
/// file protects it from now on; it does not retroactively destroy what was
/// written. Only crypto-shredding gives real deletion going forward: values
/// sealed under a key that is then retired (``Keyring/retire(id:)``) are gone
/// whatever the disk still holds.
public struct SealedFile: Sendable {
    public struct Options: Sendable, Hashable {
        /// Keep the previous generation as `<path>.previous` (sealed).
        public var keepPrevious: Bool
        /// Refuse a write up front when the volume has too little room.
        public var checksFreeSpace: Bool
        /// The permission bits of a file this write *creates*. `0o600`.
        public var newFileMode: UInt16

        public init(keepPrevious: Bool = false, checksFreeSpace: Bool = true, newFileMode: UInt16 = 0o600) {
            self.keepPrevious = keepPrevious
            self.checksFreeSpace = checksFreeSpace
            self.newFileMode = newFileMode
        }
    }

    /// What ``adopt(path:context:)`` found.
    public enum Adoption: Sendable, Hashable {
        /// There was no file.
        case absent
        /// The file already begins with a sealed header: left as it is (and
        /// not opened; ``read(_:context:)`` is what proves it).
        case alreadySealed
        /// The plaintext was sealed, in place, atomically.
        case adopted
    }

    public let keyring: Keyring
    public let fileSystem: any FileSystem
    public let options: Options

    public init(keyring: Keyring, fileSystem: any FileSystem = PosixFileSystem(), options: Options = Options()) {
        self.keyring = keyring
        self.fileSystem = fileSystem
        self.options = options
    }

    /// `AtomicFile` with no envelope: the file is the sealed value.
    private func atomicFile(keepPrevious: Bool) -> AtomicFile {
        AtomicFile(fileSystem: fileSystem, options: .init(
            envelope: false, keepPrevious: keepPrevious, checksFreeSpace: options.checksFreeSpace, newFileMode: options.newFileMode
        ))
    }

    // MARK: Writing and reading

    /// Seals `plaintext` under the keyring's current key, bound to `context`, and
    /// replaces the file at `path` with it, durably and atomically.
    ///
    /// - Throws: ``SealedStoreError``: `.keyring` if the keyring is destroyed,
    ///   `.store` for the file system (including `.durabilityUnknown`: the new
    ///   file is in place, and a power loss may undo it). A failed write leaves
    ///   the old contents.
    public func write(_ plaintext: [UInt8], to path: String, context: SealContext) throws(SealedStoreError) {
        let sealed = try seal(plaintext, context: context)
        do throws(StoreError) {
            try atomicFile(keepPrevious: options.keepPrevious).write(sealed, to: path)
        } catch {
            throw .store(error)
        }
    }

    /// The plaintext in the file at `path`, or `nil` if there is no file.
    ///
    /// - Throws: ``SealedStoreError``: `.seal(.notSealed)` for a file with no
    ///   header (plaintext: see ``adopt(path:context:)``), `.seal(.tampered)`,
    ///   `.seal(.torn)`, `.seal(.unknownKey)`; `.store` for the file system.
    ///   The file is left as it is, whatever it holds.
    public func read(_ path: String, context: SealContext) throws(SealedStoreError) -> [UInt8]? {
        let stored: AtomicFile.Contents?
        do throws(StoreError) {
            stored = try atomicFile(keepPrevious: options.keepPrevious).read(path)
        } catch {
            throw .store(error)
        }
        guard let stored else { return nil }
        do throws(SealError) {
            return try Sealing.open(stored.bytes, context: context, keyring: keyring)
        } catch {
            SealedEvents.record(Event("sealed.open_failed", level: .warning, fields: [
                .init("purpose", .string(context.purpose)), .init("kind", .string(error.label)),
                .init("source", .string(stored.source == .current ? "file" : "previous_generation")),
            ]))
            throw .seal(error)
        }
    }

    // MARK: Adopting plaintext

    /// Seals the plaintext file at `path` in place, so a file an earlier
    /// version wrote in the clear is protected from now on.
    ///
    /// 1. Reads the file as it is (the bytes, with no envelope assumed).
    /// 2. If it already begins with a sealed header, does nothing but step 5.
    /// 3. Otherwise seals it to a staged file beside it (`<path>.sealing`), made
    ///    durable, then **reads that file back, opens it with the keyring and
    ///    compares what it opens to with the plaintext**. A copy that does not
    ///    open, or opens to anything else, is removed and
    ///    ``SealedStoreError/verificationFailed(_:)`` is thrown: the plaintext
    ///    has not been touched.
    /// 4. Renames the staged file over the plaintext (atomic, and without keeping
    ///    the plaintext as a previous generation, whatever ``Options/keepPrevious``
    ///    says) and syncs the directory. Nothing but this rename ever removes
    ///    the plaintext file, so it is never gone before a verified replacement is
    ///    in place.
    /// 5. Removes every plaintext copy the store itself keeps beside it: a
    ///    `<path>.previous` and a stale `<path>.tmp` that are not sealed values,
    ///    and a staged file an interrupted call left. A sealed `.previous` is
    ///    left. (A symbolic link is followed: the neighbours are those of the
    ///    file it names.)
    ///
    /// A crash anywhere leaves the plaintext file or the sealed one, never a
    /// torn file, and a second call finishes step 5. It is safe to call at every
    /// launch.
    ///
    /// **What it cannot do:** erase. The blocks the plaintext occupied stay on
    /// an APFS or SSD volume until reused, and in any backup or snapshot made
    /// before. It does not touch `<path>.corrupt-N` files an earlier
    /// `AtomicFile` quarantined: those are the app's to inspect and remove.
    /// Adoption stops new exposure; crypto-shredding ends the old one.
    ///
    /// The mode of the file is kept (a replacement keeps the mode it
    /// replaces): an adopted `0o644` file stays `0o644`, sealed. A path with no
    /// file is ``Adoption/absent`` and nothing is touched, a stray
    /// `<path>.previous` included.
    @discardableResult
    public func adopt(path: String, context: SealContext) throws(SealedStoreError) -> Adoption {
        let plain = atomicFile(keepPrevious: false)
        let stored: AtomicFile.Contents?
        let resolved: String
        do throws(StoreError) {
            resolved = try plain.resolvedPath(path)
            stored = try plain.read(path)
        } catch {
            throw .store(error)
        }
        guard let stored else { return .absent }
        guard !Sealing.isSealed(stored.bytes) else {
            try removePlaintextNeighbours(of: resolved)
            return .alreadySealed
        }
        let sealed = try seal(stored.bytes, context: context)
        // `.durabilityUnknown` is thrown as it is: the sealed file is in
        // place, but until it is durable the leftovers may be all that a
        // power loss leaves, so they stay for the next call to remove.
        try replaceVerified(resolved, with: sealed, plaintext: stored.bytes, context: context)
        let removed = try removePlaintextNeighbours(of: resolved)
        SealedEvents.record(Event("sealed.file_adopted", level: .notice, fields: [
            .init("purpose", .string(context.purpose)), .init("bytes", .int(stored.bytes.count)),
            .init("leftoversRemoved", .int(removed)),
        ]))
        return .adopted
    }

    /// The name an adoption stages its sealed copy under, beside the file.
    static let stagedSuffix = ".sealing"

    /// Writes `sealed` to the staged name, proves it opens to `plaintext`, and
    /// only then renames it over `resolved`.
    ///
    /// The staged file is created with the mode of the file it replaces (before
    /// a byte goes in), written whole and `fullSync`ed, and only then read back,
    /// so what is compared is what the rename publishes. A leftover under the
    /// staged name is a crashed call's, and is replaced. The plaintext is not
    /// touched until the rename, and every failure before it removes the staged
    /// file and leaves the plaintext as it was.
    private func replaceVerified(
        _ resolved: String, with sealed: [UInt8], plaintext: [UInt8], context: SealContext
    ) throws(SealedStoreError) {
        let staged = resolved + Self.stagedSuffix
        let directory = Self.directory(of: resolved)
        try stage(sealed, at: staged, mode: resolved)
        try verify(staged, opensTo: plaintext, context: context)
        do throws(StoreError) {
            try fileSystem.rename(from: staged, to: resolved)
        } catch {
            discard(staged)
            throw .store(error)
        }
        // From here the sealed file is what every reader sees; a failure now
        // is not "nothing changed", as `AtomicFile` says of its own.
        do throws(StoreError) {
            try fileSystem.syncDirectory(directory)
        } catch {
            throw .store(StoreError(
                kind: .durabilityUnknown, operation: error.operation, path: resolved, errnoValue: error.errnoValue,
                detail: "the file is sealed and readers see it, but that could not be made durable (\(error.kind)); a power loss may undo it"
            ))
        }
    }

    /// Creates `staged` with the permission bits `like` has (or the options'
    /// for a new file), and writes `bytes` to it durably.
    private func stage(_ bytes: [UInt8], at staged: String, mode like: String) throws(SealedStoreError) {
        do throws(StoreError) {
            if options.checksFreeSpace {
                // A volume that cannot say how much room it has is not a reason to refuse.
                let free: UInt64? = try? fileSystem.freeSpace(at: Self.directory(of: staged))
                if let free, free < UInt64(bytes.count) {
                    throw StoreError(kind: .diskFull, operation: "preflight", path: staged, detail: "\(bytes.count) bytes needed, \(free) free")
                }
            }
            if try fileSystem.exists(staged) {
                // A leftover of a crashed call is ours to replace; a file that is
                // not one is somebody's, and is not removed to make room.
                guard Self.isSealedOrItsStart(try fileSystem.readAll(staged)) else {
                    throw StoreError(
                        kind: .alreadyExists, operation: "stage", path: staged,
                        detail: "a file that is not a sealed copy is where adoption stages its copy; move it away"
                    )
                }
                try fileSystem.remove(staged)
            }
            let mode = try fileSystem.permissions(of: like) ?? options.newFileMode
            let file = try fileSystem.open(staged, mode: .createExclusive)
            do throws(StoreError) {
                try fileSystem.setPermissions(file, to: mode)
                try fileSystem.write(file, bytes, at: 0)
                try fileSystem.fullSync(file)
                try fileSystem.close(file)
            } catch {
                _ = Result { () throws(StoreError) in try fileSystem.close(file) }
                discard(staged)
                throw error
            }
        } catch {
            throw .store(error)
        }
    }

    /// Reads `staged` back and opens it as a reader would; removes it and
    /// throws unless it opens to exactly `plaintext`.
    private func verify(_ staged: String, opensTo plaintext: [UInt8], context: SealContext) throws(SealedStoreError) {
        let onDisk: [UInt8]
        do throws(StoreError) {
            onDisk = try fileSystem.readAll(staged)
        } catch {
            discard(staged)
            throw .store(error)
        }
        let opened: [UInt8]
        do throws(SealError) {
            opened = try Sealing.open(onDisk, context: context, keyring: keyring)
        } catch {
            discard(staged)
            throw .verificationFailed(error)
        }
        guard opened == plaintext else {
            discard(staged)
            throw .verificationFailed(nil)
        }
    }

    /// Removes a staged copy that must not stay. Best effort, because the
    /// failure being reported is the one worth reporting: a copy that stays is a
    /// sealed value, and the next call replaces it.
    private func discard(_ staged: String) {
        _ = Result { () throws(StoreError) in
            if try fileSystem.exists(staged) { try fileSystem.remove(staged) }
        }
    }

    /// Whether `bytes` could be all or the start of a sealed value: what an
    /// adoption's own staged file holds, whole or cut short by a crash.
    private static func isSealedOrItsStart(_ bytes: [UInt8]) -> Bool {
        Sealing.isSealed(bytes) || Sealing.magic.starts(with: bytes)
    }

    /// Removes `<resolved>.previous` and `<resolved>.tmp` unless they are sealed
    /// values, and a staged file an interrupted adoption left, and syncs the
    /// directory if anything went. Returns how many went.
    @discardableResult
    private func removePlaintextNeighbours(of resolved: String) throws(SealedStoreError) -> Int {
        var removed = 0
        do throws(StoreError) {
            for suffix in [".previous", ".tmp"] {
                let neighbour = resolved + suffix
                guard try fileSystem.exists(neighbour) else { continue }
                let bytes = try fileSystem.readAll(neighbour)
                guard !Sealing.isSealed(bytes) else { continue }
                try fileSystem.remove(neighbour)
                removed += 1
            }
            // The staged copy is ours: sealed, or the start of it if the crash
            // came while it was written. Something else under that name is not.
            let staged = resolved + Self.stagedSuffix
            if try fileSystem.exists(staged), Self.isSealedOrItsStart(try fileSystem.readAll(staged)) {
                try fileSystem.remove(staged)
                removed += 1
            }
            if removed > 0 { try fileSystem.syncDirectory(Self.directory(of: resolved)) }
        } catch {
            throw .store(error)
        }
        return removed
    }

    private static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "." }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }

    private func seal(_ plaintext: [UInt8], context: SealContext) throws(SealedStoreError) -> [UInt8] {
        let key: SealingKey
        do throws(KeyringError) {
            key = try keyring.current
        } catch {
            throw .keyring(error)
        }
        do throws(SealError) {
            return try Sealing.seal(plaintext, context: context, key: key)
        } catch {
            throw .seal(error)
        }
    }
}
#endif
