/// An open file, as the file system hands it out.
///
/// An opaque token rather than a raw descriptor, so a simulated file system
/// can issue its own and a stale one is a typed error, not a stray `close`
/// of someone else's descriptor.
public struct OpenFile: Sendable, Hashable, CustomStringConvertible {
    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public var description: String { "file#\(rawValue)" }
}

/// How ``FileSystem/open(_:mode:)`` opens a path.
public enum OpenMode: Sendable, Hashable {
    /// An existing file, for reading.
    case read
    /// An existing file, for reading and writing.
    case readWrite
    /// A new file, for reading and writing. Fails with `EEXIST` if the path
    /// exists: a stale temporary file is never silently adopted.
    case createExclusive
    /// The file if it exists, a new empty one otherwise. Never truncates.
    case readWriteCreate
}

/// Exactly the operations `StoicStore` needs from a file system.
///
/// The surface is deliberately small and positional: the store writes *at an
/// offset* (a journal appends at the end it tracks; there is no shared file
/// position to get wrong), reads *at an offset*, and says when it wants
/// durability. `PosixFileSystem` is the real implementation;
/// ``SimulatedFileSystem`` models what survives a crash, so tests can stop
/// the world after every call and check what recovery finds.
///
/// ## What durability means here
///
/// - ``write(_:_:at:)`` and ``truncate(_:to:)`` change what readers see at
///   once but are *not* durable until ``fullSync(_:)`` on that file.
/// - Creating, renaming and removing a file change a *directory*, which is
///   not durable until ``syncDirectory(_:)`` on that directory. Syncing a
///   file does not sync its name.
///
/// Implementations must be safe to call from many threads; the store keeps
/// its own ordering. Calls block: persistence is small and local, so run it
/// off the main actor when latency matters (an `Outbox` does its I/O on its
/// own actor).
public protocol FileSystem: Sendable {
    func open(_ path: String, mode: OpenMode) throws(StoreError) -> OpenFile

    /// Up to `count` bytes starting at `offset`; fewer only at end of file.
    func read(_ file: OpenFile, at offset: Int, count: Int) throws(StoreError) -> [UInt8]

    /// Writes all of `bytes` at `offset`, extending the file (a gap reads as
    /// zeros). Not durable until ``fullSync(_:)``.
    func write(_ file: OpenFile, _ bytes: [UInt8], at offset: Int) throws(StoreError)

    /// The current size in bytes.
    func size(of file: OpenFile) throws(StoreError) -> Int

    /// Sets the size, zero-extending or cutting. Not durable until ``fullSync(_:)``.
    func truncate(_ file: OpenFile, to size: Int) throws(StoreError)

    /// Makes the file's data and size durable: `F_FULLFSYNC` where the
    /// platform has it (plain `fsync` on Apple platforms does not flush the
    /// drive's cache), `fsync` where it does not.
    func fullSync(_ file: OpenFile) throws(StoreError)

    func close(_ file: OpenFile) throws(StoreError)

    /// Makes the creates, renames and removes in `directory` durable.
    func syncDirectory(_ directory: String) throws(StoreError)

    /// Atomically renames, replacing `destination` if it exists. Not durable
    /// until ``syncDirectory(_:)``.
    func rename(from source: String, to destination: String) throws(StoreError)

    /// Removes a file. Not durable until ``syncDirectory(_:)``.
    func remove(_ path: String) throws(StoreError)

    /// The names (not paths) in `directory`, sorted, without `.` and `..`.
    func list(directory: String) throws(StoreError) -> [String]

    func exists(_ path: String) throws(StoreError) -> Bool

    /// Bytes available to this process on the volume holding `directory`.
    func freeSpace(at directory: String) throws(StoreError) -> UInt64

    /// Creates `path` and any missing parents; succeeds if it exists.
    func createDirectory(_ path: String) throws(StoreError)

    /// The permission bits (`0o600`, `0o644`, …) of the file at `path`,
    /// following a symbolic link; `nil` if there is no such file.
    ///
    /// ``AtomicFile`` uses this to give a replacement the permissions of the
    /// file it replaces. The default returns `nil` ("not known"), which makes
    /// a replacement take the mode for new files; a file system that has
    /// permissions must implement it.
    func permissions(of path: String) throws(StoreError) -> UInt16?

    /// Sets the permission bits of an open file (`fchmod`). Not durable until
    /// ``fullSync(_:)``. The default does nothing, for a file system with no
    /// permissions to set.
    func setPermissions(_ file: OpenFile, to permissions: UInt16) throws(StoreError)

    /// Where the symbolic link at `path` points, exactly as it is stored
    /// (it may be relative to the link's directory); `nil` if `path` is not a
    /// link or does not exist.
    ///
    /// ``AtomicFile`` follows links with this, so a write replaces the file
    /// the link names rather than the link. The default returns `nil` ("no
    /// links here").
    func readLink(_ path: String) throws(StoreError) -> String?

    /// Atomically swaps two existing items, files or directories alike, so
    /// each name holds what the other held (`renamex_np` with `RENAME_SWAP`).
    /// Fails with `EXDEV` if they are on different volumes, and with `ENOENT`
    /// if either does not exist. Not durable until ``syncDirectory(_:)`` on
    /// both parent directories. The default throws `.unsupported`, for a file
    /// system that cannot do it.
    func exchange(_ first: String, _ second: String) throws(StoreError)

    /// Removes the item at `path`: a file, a symbolic link (not what it
    /// points to), or a directory and everything in it. Not durable until
    /// ``syncDirectory(_:)``. The default is ``remove(_:)``, for a file
    /// system with no directories to empty.
    func removeTree(_ path: String) throws(StoreError)

    /// Takes an exclusive advisory lock on an open file, without waiting.
    /// Returns `false` if another open file already holds it. ``FileLock``
    /// builds on this.
    ///
    /// The lock belongs to the *open file* (`flock`), not the process, so two
    /// opens of one path conflict even in one process; it is released by
    /// ``unlock(_:)``, by ``close(_:)``, and by the process dying. The default
    /// throws `.unsupported`, for a file system with no locks.
    func tryLock(_ file: OpenFile) throws(StoreError) -> Bool

    /// Releases the lock ``tryLock(_:)`` took; harmless if the file holds none.
    func unlock(_ file: OpenFile) throws(StoreError)
}

extension FileSystem {
    public func readLink(_ path: String) throws(StoreError) -> String? { nil }

    public func tryLock(_ file: OpenFile) throws(StoreError) -> Bool {
        throw StoreError(kind: .unsupported, operation: "flock", detail: "this file system has no advisory locks")
    }

    public func unlock(_ file: OpenFile) throws(StoreError) {}

    public func exchange(_ first: String, _ second: String) throws(StoreError) {
        throw StoreError(kind: .unsupported, operation: "exchange", path: first, detail: "this file system cannot swap two items atomically")
    }

    public func removeTree(_ path: String) throws(StoreError) { try remove(path) }

    public func permissions(of path: String) throws(StoreError) -> UInt16? { nil }

    public func setPermissions(_ file: OpenFile, to permissions: UInt16) throws(StoreError) {}
}

extension FileSystem {
    /// The whole file at `path`, opened, read and closed.
    public func readAll(_ path: String) throws(StoreError) -> [UInt8] {
        let file = try open(path, mode: .read)
        let bytes: [UInt8]
        do throws(StoreError) {
            bytes = try read(file, at: 0, count: try size(of: file))
        } catch {
            do throws(StoreError) {
                try close(file)
            } catch {
                // The read's error is the one worth reporting; a close that
                // also fails adds nothing the caller can act on.
            }
            throw error
        }
        try close(file)
        return bytes
    }
}

/// Path arithmetic on `/`-separated strings, without Foundation.
enum StorePath {
    /// The directory part: everything before the last `/` (`"."` if none).
    static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "." }
        if slash == path.startIndex { return "/" }
        return String(path[..<slash])
    }

    /// The last component.
    static func name(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    static func join(_ directory: String, _ name: String) -> String {
        if directory == "." { return name }
        return directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }
}
