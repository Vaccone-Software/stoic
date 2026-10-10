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
