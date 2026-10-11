internal import Stoic

/// Whole-file writes that survive a crash, with the previous version kept.
///
/// `Data.write(to:)` leaves half a file after a crash; `.atomic` writes a
/// temporary and renames it, but still ends in plain `fsync`, which on Apple
/// platforms does not flush the drive's cache, and never syncs the
/// directory, so the rename itself can be lost. `AtomicFile.write` does the
/// whole sequence:
///
/// 1. check there is room (so a full disk is refused before anything is touched);
/// 2. write the new bytes to `<path>.tmp` (wrapped in a checksum envelope),
///    with the permissions of the file being replaced;
/// 3. `fullSync` the temporary file;
/// 4. if a previous generation is kept, demote the current file to
///    `<path>.previous` (only if it is itself intact);
/// 5. rename the temporary over `<path>`;
/// 6. sync the directory.
///
/// Whatever instant the machine dies, ``read(_:options:validate:)`` finds
/// exactly the old bytes or exactly the new, and once `write` has returned it
/// finds the new. That is checked, at every crash point and every legal
/// reordering, by this package's tests.
///
///     let settings = AtomicFile(options: .init(keepPrevious: true))
///     try settings.write(encode(prefs), to: path)
///
///     do {
///         if let saved = try settings.read(path, validate: { decode($0) != nil }) {
///             prefs = decode(saved.bytes)!
///         }
///     } catch where error.kind == .corrupt {
///         prefs = .defaults       // every copy was corrupt; they are quarantined
///     }
///
/// ## Contract
///
/// - **Permissions.** A replacement has the permission bits of the file it
///   replaces, so a file made private stays private (a write that made a new
///   file every time would hand it the default mode, usually `0o644`). A file
///   that does not exist yet is created with ``Options/newFileMode``. The
///   bits are set before any data is written.
/// - **Symbolic links are followed.** Writing to a path that is a link
///   replaces the file the link names, atomically and beside that file (its
///   directory is synced), and leaves the link in place; a dotfiles setup can
///   keep a settings file behind a link. `read` follows it too, and the
///   previous generation and quarantined copies live beside the target.
/// - **One writer per path.** Concurrent writers to the same path race on
///   the temporary name. Cross-process locking is out of scope.
/// - **Cancellation and threads.** Calls are synchronous and blocking, and
///   not cancellation points. Run them off the main actor if latency matters.
/// - **Errors.** Every failure is a ``StoreError``; a failed write leaves the
///   previous contents in place and removes its temporary file.
public struct AtomicFile: Sendable {
    public struct Options: Sendable, Hashable {
        /// Wrap the bytes in a checksum envelope, so a reader can tell a
        /// corrupt file from a valid one. Without it the file is exactly the
        /// bytes, and corruption is only caught by `validate`.
        public var envelope: Bool

        /// Keep the previous generation as `<path>.previous`, and fall back to
        /// it when the current file is missing or corrupt.
        public var keepPrevious: Bool

        /// Refuse a write up front when the volume has less than the file's
        /// size free, rather than part-way through.
        public var checksFreeSpace: Bool

        /// The most quarantined `.corrupt-N` files kept per path; older ones
        /// are removed.
        public var quarantineLimit: Int

        /// The permission bits of a file this write *creates*: `0o600` for
        /// anything private. A file that already exists keeps the bits it
        /// has, whatever this says (see ``AtomicFile``).
        public var newFileMode: UInt16

        public init(
            envelope: Bool = true, keepPrevious: Bool = false, checksFreeSpace: Bool = true, quarantineLimit: Int = 8,
            newFileMode: UInt16 = 0o644
        ) {
            self.envelope = envelope
            self.keepPrevious = keepPrevious
            self.checksFreeSpace = checksFreeSpace
            self.quarantineLimit = quarantineLimit
            self.newFileMode = newFileMode
        }
    }

    /// What ``read(_:options:validate:)`` found.
    public struct Contents: Sendable, Hashable {
        public enum Source: Sendable, Hashable {
            /// The file at the path.
            case current
            /// The previous generation, because the current one was missing or corrupt.
            case previous
        }

        public let bytes: [UInt8]
        public let source: Source
    }

    public let fileSystem: any FileSystem
    public let options: Options

    public init(fileSystem: any FileSystem = PosixFileSystem(), options: Options = Options()) {
        self.fileSystem = fileSystem
        self.options = options
    }

    // MARK: Writing

    /// Replaces the file at `path` with `bytes`, durably and atomically.
    ///
    /// - Parameter options: Overrides the options given at `init` for this call.
    public func write(_ bytes: [UInt8], to requested: String, options override: Options? = nil) throws(StoreError) {
        let options = override ?? options
        let fileSystem = fileSystem
        // Everything below happens beside the real file: the temporary, the
        // previous generation and the directory sync. Renaming over a link
        // would replace the link and leave its target as it was.
        let path = try resolvingLinks(requested)
        let image = options.envelope ? Envelope.seal(bytes) : bytes
        let directory = StorePath.directory(of: path)
        let temporary = path + ".tmp"

        if options.checksFreeSpace {
            // A volume that cannot say how much room it has is not a reason to refuse.
            let free: UInt64? = try? fileSystem.freeSpace(at: directory)
            if let free, free < UInt64(image.count) {
                throw StoreError(kind: .diskFull, operation: "preflight", path: path, detail: "\(image.count) bytes needed, \(free) free")
            }
        }

        // A temporary left by a crash is ours (one writer per path): remove it
        // so the exclusive create below cannot trip on it.
        if try fileSystem.exists(temporary) {
            try fileSystem.remove(temporary)
            StoreEvents.record(Event("store.temp_removed", level: .info, fields: [.init("path", .string(temporary))]))
        }

        do throws(StoreError) {
            // The replacement is as private as what it replaces; a new file
            // gets the mode the caller asked for. Set before a byte is
            // written, so a secret is never in a file more open than it
            // should be, even for an instant.
            let mode = try fileSystem.permissions(of: path) ?? options.newFileMode
            let file = try fileSystem.open(temporary, mode: .createExclusive)
            do throws(StoreError) {
                try fileSystem.setPermissions(file, to: mode)
                try fileSystem.write(file, image, at: 0)
                try fileSystem.fullSync(file)
            } catch {
                closeQuietly(file)
                throw error
            }
            try fileSystem.close(file)

            if options.keepPrevious, try fileSystem.exists(path) {
                if try isIntact(path, options: options) {
                    try fileSystem.rename(from: path, to: path + ".previous")
                } else {
                    // Demoting a corrupt file would replace a good previous
                    // generation with garbage.
                    quarantine(path, reason: "corrupt when about to be replaced", options: options)
                }
            }
            try fileSystem.rename(from: temporary, to: path)
        } catch {
            removeQuietly(temporary)
            throw error
        }
        try fileSystem.syncDirectory(directory)
    }

    // MARK: Reading

    /// The bytes last written to `path`, or the generation before if the
    /// latest is gone or corrupt; `nil` if nothing was ever written.
    ///
    /// A corrupt file is renamed aside to `<path>.corrupt-N` (and reported as
    /// `store.corrupt_quarantined`), never deleted. Falling back to the
    /// previous generation is reported as `store.recovered_previous`.
    ///
    /// - Parameter validate: Called with the payload of a file whose envelope
    ///   is intact; return `false` if the app cannot use it (it will not
    ///   decode, say). The file is then treated as corrupt.
    /// - Throws: ``StoreError`` of kind `.corrupt` if files existed but none
    ///   was usable; they are quarantined, so the next read returns `nil`.
    public func read(
        _ requested: String,
        options override: Options? = nil,
        validate: (([UInt8]) -> Bool)? = nil
    ) throws(StoreError) -> Contents? {
        let options = override ?? options
        let path = try resolvingLinks(requested)
        var candidates: [(String, Contents.Source)] = [(path, .current)]
        if options.keepPrevious { candidates.append((path + ".previous", .previous)) }

        var problem: String?
        for (candidate, source) in candidates {
            let raw: [UInt8]
            do throws(StoreError) {
                raw = try fileSystem.readAll(candidate)
            } catch where error.kind == .notFound {
                if source == .current { problem = "missing" }
                continue
            }
            switch check(raw, options: options, validate: validate) {
            case .valid(let payload):
                if source == .previous {
                    StoreEvents.record(Event("store.recovered_previous", level: .warning, fields: [
                        .init("path", .string(path)), .init("reason", .string(problem ?? "missing")),
                    ]))
                }
                return Contents(bytes: payload, source: source)
            case .invalid(let reason):
                quarantine(candidate, reason: reason, options: options)
                if source == .current { problem = "corrupt: \(reason)" }
                else { problem = (problem.map { $0 + "; " } ?? "") + "previous corrupt: \(reason)" }
            }
        }
        // Nothing usable. If every candidate was merely absent there is no
        // saved file at all; a candidate that was corrupt was quarantined.
        if let problem, problem != "missing" {
            throw StoreError(kind: .corrupt, operation: "read", path: path, detail: problem)
        }
        return nil
    }

    // MARK: Helpers

    /// `path`, if it is a symbolic link, replaced by the file it leads to
    /// (through a chain of links, a relative link being relative to its own
    /// directory). A link to nothing resolves to where the file would be:
    /// the write creates it there, as `>` through a dangling link does.
    private func resolvingLinks(_ path: String) throws(StoreError) -> String {
        var current = path
        for _ in 0..<Self.maxLinkDepth {
            guard let target = try fileSystem.readLink(current) else { return current }
            current = target.hasPrefix("/") ? target : StorePath.join(StorePath.directory(of: current), target)
        }
        throw StoreError(kind: .invalidArgument, operation: "resolve", path: path, detail: "too many levels of symbolic links")
    }

    private static let maxLinkDepth = 40

    private enum Check {
        case valid([UInt8])
        case invalid(String)
    }

    private func check(_ raw: [UInt8], options: Options, validate: (([UInt8]) -> Bool)?) -> Check {
        let payload: [UInt8]
        if options.envelope {
            switch Envelope.open(raw) {
            case .success(let opened): payload = opened
            case .failure(let failure): return .invalid(failure.description)
            }
        } else {
            payload = raw
        }
        if let validate, !validate(payload) { return .invalid("rejected by the app's validation") }
        return .valid(payload)
    }

    /// Whether `path` holds a file the reader would accept (envelope only).
    private func isIntact(_ path: String, options: Options) throws(StoreError) -> Bool {
        guard options.envelope else { return true }
        let raw: [UInt8]
        do throws(StoreError) {
            raw = try fileSystem.readAll(path)
        } catch where error.kind == .notFound {
            return false
        }
        if case .success = Envelope.open(raw) { return true }
        return false
    }

    /// Renames a corrupt file to `<path>.corrupt-N` and prunes old ones. A
    /// quarantine that cannot be carried out (a read-only volume) is reported
    /// and does not stop the read: the fallback copy is still good.
    private func quarantine(_ path: String, reason: String, options: Options) {
        let directory = StorePath.directory(of: path)
        let prefix = StorePath.name(of: path) + ".corrupt-"
        var target = ""
        do throws(StoreError) {
            let existing = try fileSystem.list(directory: directory)
                .compactMap { name -> Int? in name.hasPrefix(prefix) ? Int(name.dropFirst(prefix.count)) : nil }
                .sorted()
            target = StorePath.join(directory, prefix + String((existing.last ?? 0) + 1))
            try fileSystem.rename(from: path, to: target)
            try fileSystem.syncDirectory(directory)
            for old in existing.dropLast(max(0, options.quarantineLimit - 1)) {
                try fileSystem.remove(StorePath.join(directory, prefix + String(old)))
            }
        } catch {
            StoreEvents.record(Event("store.corrupt_quarantined", level: .error, fields: [
                .init("path", .string(path)), .init("reason", .string(reason)), .init("quarantined", .bool(false)),
                .init("error", .error(error)),
            ]))
            return
        }
        StoreEvents.record(Event("store.corrupt_quarantined", level: .warning, fields: [
            .init("path", .string(path)), .init("reason", .string(reason)), .init("quarantined", .bool(true)),
            .init("movedTo", .string(target)),
        ]))
    }

    private func closeQuietly(_ file: OpenFile) {
        do throws(StoreError) {
            try fileSystem.close(file)
        } catch {
            // Already failing; the original error is the one to report.
        }
    }

    private func removeQuietly(_ path: String) {
        do throws(StoreError) {
            if try fileSystem.exists(path) { try fileSystem.remove(path) }
        } catch {
            // The temporary is cleaned up on the next write; the original
            // error is the one to report.
        }
    }
}

extension AtomicFile.Contents: CustomStringConvertible {
    public var description: String { "\(bytes.count) bytes from the \(source) file" }
}
