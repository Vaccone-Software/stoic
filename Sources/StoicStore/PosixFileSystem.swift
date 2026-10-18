internal import Stoic
internal import Synchronization

#if canImport(Darwin)
internal import Darwin
#elseif canImport(Glibc)
internal import Glibc
#else
#error("StoicStore needs Darwin or Glibc")
#endif

/// The real file system, over POSIX.
///
/// `fullSync` is `F_FULLFSYNC` on Apple platforms. Plain `fsync` there
/// returns once the data reaches the *drive*, which may hold it in a volatile
/// cache; only `F_FULLFSYNC` asks the drive to flush. Where the call is
/// unsupported (`ENOTSUP`, `EINVAL`, `ENOTTY`: some network and FUSE volumes)
/// it falls back to `fsync` and reports `store.fullsync_unavailable` once.
/// On Glibc, `fsync` already means a flush.
///
/// Calls restart on `EINTR`. A short write is continued until the whole
/// buffer is down or the system reports why not.
///
/// `tryLock` is `flock(LOCK_EX | LOCK_NB)`: advisory, per open file, and
/// dropped by the kernel when the descriptor closes or the process dies.
///
/// ## Who can read what the store writes
///
/// Every file this file system creates, whoever asks (a ``Journal``, its
/// snapshot, its lock file, an ``AtomicFile``'s temporary, an ``Outbox``), is
/// created with ``newFileMode``, and every directory
/// ``createDirectory(_:)`` makes with ``newDirectoryMode``. One value at the
/// file system is one answer for the whole store, where a mode on each
/// type would have left the files nobody thought to ask about (a `.lock`, a
/// compaction's temporary) at the default:
///
///     let disk = PosixFileSystem(newFileMode: 0o600, newDirectoryMode: 0o700)
///     try disk.createDirectory(dir)
///     let outbox = try Outbox<Note>.open(at: dir + "/outbox", codec: .json(), fileSystem: disk)
///
/// The mode is the argument of `open(2)` and `mkdir(2)`, so it is in force
/// from the instant the name exists: there is no moment when a private file
/// is readable by others, which a `chmod` after the create could not promise.
/// The process's umask still applies, as it does to every file the process
/// creates, and it can only *remove* bits: a request for `0o600` is `0o600`
/// under any umask that leaves the owner read and write, and the defaults
/// (`0o644`, `0o755`) are what they always were, narrowed by a stricter umask.
/// The umask is never changed or cleared (it is process-wide, and another
/// thread may be creating files at that moment), and no `fchmod` follows the
/// create to widen the result: a store that asks for `0o664` under a umask of
/// `022` gets `0o644`. ``AtomicFile`` is the one exception, and says so: it
/// sets its file's bits exactly.
///
/// Only what is *created* is given the mode. A file or directory that
/// already exists keeps the bits it has, so adopting a stricter mode does not
/// tighten what an earlier launch made (``setPermissions(_:to:)`` does that,
/// for a file the app has open); a parent that a ``createDirectory(_:)``
/// finds already there is left as it is.
public final class PosixFileSystem: FileSystem {
    private let reportedFallback = Atomic<Bool>(false)

    /// The permission bits of a file this file system creates, before the
    /// process's umask: `open(2)`'s `mode`.
    public let newFileMode: UInt16

    /// The permission bits of a directory ``createDirectory(_:)`` creates,
    /// before the process's umask: `mkdir(2)`'s `mode`.
    public let newDirectoryMode: UInt16

    /// A file system whose new files are `0o644` and new directories `0o755`
    /// (before the umask), as it has always been.
    public convenience init() {
        self.init(newFileMode: 0o644, newDirectoryMode: 0o755)
    }

    /// - Parameters:
    ///   - newFileMode: The bits of a new file. Default `0o644`. Use `0o600`
    ///     for anything private.
    ///   - newDirectoryMode: The bits of a new directory. Default `0o755`.
    ///     Use `0o700` for anything private.
    ///
    /// Preconditions: only permission bits (`0o777` at most), and enough for
    /// the store to use what it creates: the owner needs read and write on a
    /// file and read, write and search on a directory, since the store opens
    /// its files again and writes into its directories.
    public init(newFileMode: UInt16 = 0o644, newDirectoryMode: UInt16 = 0o755) {
        precondition(newFileMode & ~0o777 == 0 && newDirectoryMode & ~0o777 == 0, "a mode is permission bits, 0o777 at most")
        precondition(newFileMode & 0o600 == 0o600, "the store reopens its files: the owner needs read and write")
        precondition(newDirectoryMode & 0o700 == 0o700, "the store writes into its directories: the owner needs read, write and search")
        self.newFileMode = newFileMode
        self.newDirectoryMode = newDirectoryMode
    }

    public func open(_ path: String, mode: OpenMode) throws(StoreError) -> OpenFile {
        var flags: Int32 = O_CLOEXEC
        switch mode {
        case .read: flags |= O_RDONLY
        case .readWrite: flags |= O_RDWR
        case .createExclusive: flags |= O_RDWR | O_CREAT | O_EXCL
        case .readWriteCreate: flags |= O_RDWR | O_CREAT
        }
        while true {
            let descriptor = CSys.openFile(path, flags: flags, permissions: mode_t(newFileMode))
            if descriptor >= 0 { return OpenFile(rawValue: descriptor) }
            if errno != EINTR { throw StoreError(errno: errno, operation: "open", path: path) }
        }
    }

    public func read(_ file: OpenFile, at offset: Int, count: Int) throws(StoreError) -> [UInt8] {
        guard offset >= 0, count >= 0 else {
            throw StoreError(kind: .invalidArgument, operation: "read", detail: "negative offset or count")
        }
        var result: [UInt8] = []
        result.reserveCapacity(count)
        while result.count < count {
            let (chunk, failure) = CSys.readAt(file.rawValue, count: count - result.count, offset: offset + result.count)
            if let failure {
                if failure == EINTR { continue }
                throw StoreError(errno: failure, operation: "read")
            }
            if chunk.isEmpty { break } // end of file
            result.append(contentsOf: chunk)
        }
        return result
    }

    public func write(_ file: OpenFile, _ bytes: [UInt8], at offset: Int) throws(StoreError) {
        guard offset >= 0 else {
            throw StoreError(kind: .invalidArgument, operation: "write", detail: "negative offset")
        }
        var written = 0
        while written < bytes.count {
            let (count, failure) = CSys.writeAt(file.rawValue, bytes, from: written, offset: offset + written)
            if let failure {
                if failure == EINTR { continue }
                throw StoreError(errno: failure, operation: "write")
            }
            if count == 0 { throw StoreError(errno: ENOSPC, operation: "write") } // no progress: treat as full
            written += count
        }
    }

    public func size(of file: OpenFile) throws(StoreError) -> Int {
        let (size, failure) = CSys.fileSize(file.rawValue)
        if let failure { throw StoreError(errno: failure, operation: "fstat") }
        return size
    }

    public func truncate(_ file: OpenFile, to size: Int) throws(StoreError) {
        while CSys.truncateFile(file.rawValue, to: size) != 0 {
            if errno != EINTR { throw StoreError(errno: errno, operation: "ftruncate") }
        }
    }

    public func fullSync(_ file: OpenFile) throws(StoreError) {
        #if canImport(Darwin)
        while CSys.fullFsync(file.rawValue) != 0 {
            let failure = errno
            if failure == EINTR { continue }
            guard failure == ENOTSUP || failure == EINVAL || failure == ENOTTY else {
                throw StoreError(errno: failure, operation: "fcntl(F_FULLFSYNC)")
            }
            if !reportedFallback.exchange(true, ordering: .relaxed) {
                Ambient.current.instrumentation.record(Event(
                    "store.fullsync_unavailable", level: .notice,
                    fields: [.init("errno", .int(Int(failure)))]
                ))
            }
            try plainSync(file)
            return
        }
        #else
        try plainSync(file)
        #endif
    }

    public func sync(_ file: OpenFile) throws(StoreError) {
        try plainSync(file)
    }

    private func plainSync(_ file: OpenFile) throws(StoreError) {
        while CSys.fsyncFile(file.rawValue) != 0 {
            if errno != EINTR { throw StoreError(errno: errno, operation: "fsync") }
        }
    }

    public func close(_ file: OpenFile) throws(StoreError) {
        // Not restarted on EINTR: after an interrupted close the descriptor
        // state is unspecified, and closing again could close a descriptor
        // another thread has since been given.
        if CSys.closeFile(file.rawValue) != 0, errno != EINTR {
            throw StoreError(errno: errno, operation: "close")
        }
    }

    public func syncDirectory(_ directory: String) throws(StoreError) {
        let descriptor = try open(directory, mode: .read)
        do throws(StoreError) {
            try fullSync(descriptor)
        } catch {
            do throws(StoreError) {
                try close(descriptor)
            } catch {
                // Reporting the sync failure; the close adds nothing.
            }
            throw error
        }
        try close(descriptor)
    }

    public func rename(from source: String, to destination: String) throws(StoreError) {
        if CSys.renamePath(source, to: destination) != 0 {
            throw StoreError(errno: errno, operation: "rename", path: source)
        }
    }

    public func exchange(_ first: String, _ second: String) throws(StoreError) {
        if CSys.exchangePaths(first, second) != 0 {
            throw StoreError(errno: errno, operation: "renamex_np", path: first)
        }
    }

    public func removeTree(_ path: String) throws(StoreError) {
        let (isDirectory, failure) = CSys.isDirectory(path)
        if let failure { throw StoreError(errno: failure, operation: "lstat", path: path) }
        guard isDirectory else { return try remove(path) }
        for name in try list(directory: path) {
            try removeTree(StorePath.join(path, name))
        }
        if CSys.removeDirectory(path) != 0 {
            throw StoreError(errno: errno, operation: "rmdir", path: path)
        }
    }

    public func remove(_ path: String) throws(StoreError) {
        if CSys.unlinkPath(path) != 0 {
            throw StoreError(errno: errno, operation: "unlink", path: path)
        }
    }

    public func list(directory: String) throws(StoreError) -> [String] {
        let (names, failure) = CSys.listDirectory(directory)
        if let failure { throw StoreError(errno: failure, operation: "readdir", path: directory) }
        return names.sorted()
    }

    public func exists(_ path: String) throws(StoreError) -> Bool {
        if CSys.accessPath(path) == 0 { return true }
        if errno == ENOENT || errno == ENOTDIR { return false }
        throw StoreError(errno: errno, operation: "access", path: path)
    }

    public func freeSpace(at directory: String) throws(StoreError) -> UInt64 {
        let (available, failure) = CSys.availableBytes(directory)
        if let failure { throw StoreError(errno: failure, operation: "statvfs", path: directory) }
        return available
    }

    public func permissions(of path: String) throws(StoreError) -> UInt16? {
        let (bits, failure) = CSys.permissionBits(of: path)
        if let failure {
            if failure == ENOENT || failure == ENOTDIR { return nil }
            throw StoreError(errno: failure, operation: "stat", path: path)
        }
        return bits
    }

    public func setPermissions(_ file: OpenFile, to permissions: UInt16) throws(StoreError) {
        while CSys.changeMode(file.rawValue, to: mode_t(permissions)) != 0 {
            if errno != EINTR { throw StoreError(errno: errno, operation: "fchmod") }
        }
    }

    public func readLink(_ path: String) throws(StoreError) -> String? {
        let (target, failure) = CSys.linkTarget(of: path)
        if let failure {
            // Not a link (EINVAL) or not there at all: either way, nothing to follow.
            if failure == EINVAL || failure == ENOENT || failure == ENOTDIR { return nil }
            throw StoreError(errno: failure, operation: "readlink", path: path)
        }
        return target
    }

    public func tryLock(_ file: OpenFile) throws(StoreError) -> Bool {
        while CSys.lockFile(file.rawValue, operation: LOCK_EX | LOCK_NB) != 0 {
            let failure = errno
            if failure == EINTR { continue }
            if failure == EWOULDBLOCK { return false }
            throw StoreError(errno: failure, operation: "flock")
        }
        return true
    }

    public func unlock(_ file: OpenFile) throws(StoreError) {
        while CSys.lockFile(file.rawValue, operation: LOCK_UN) != 0 {
            if errno != EINTR { throw StoreError(errno: errno, operation: "flock(LOCK_UN)") }
        }
    }

    /// Creates `path` and any missing parents, and syncs the parent of each
    /// one it created: a new directory is a name in its parent, and without
    /// the sync a power loss can take it, and every file written into it
    /// since, however carefully those were synced.
    ///
    /// Each directory is made with ``newDirectoryMode`` (`mkdir(2)`'s mode, so
    /// it is private from the instant it exists, under the umask); one that is
    /// already there is left as it is.
    public func createDirectory(_ path: String) throws(StoreError) {
        var prefix = path.hasPrefix("/") ? "/" : ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            prefix = prefix.isEmpty || prefix == "/" ? prefix + component : prefix + "/" + component
            if CSys.makeDirectory(prefix, permissions: mode_t(newDirectoryMode)) == 0 {
                try syncDirectory(StorePath.directory(of: prefix))
            } else if errno != EEXIST {
                throw StoreError(errno: errno, operation: "mkdir", path: prefix)
            }
        }
    }
}

/// Every raw system call this module makes.
///
/// Strict memory safety makes any call that passes a pointer an `unsafe`
/// expression. POSIX takes pointers for paths and buffers, and Swift's
/// `String` and `Array` bridge to them only through unsafe APIs, so the calls
/// are gathered here, each wrapped once in `unsafe` with its reason beside it:
/// the pointer is derived from a Swift value that is alive for the whole call,
/// the length passed is that value's count, and nothing retains the pointer
/// after the call returns. Callers read `errno` immediately after a failing
/// call, before anything else can overwrite it.
private enum CSys {
    static func openFile(_ path: String, flags: Int32, permissions: mode_t) -> Int32 {
        // The path's C string lives for the call; open copies it.
        unsafe open(path, flags, permissions)
    }

    static func readAt(_ descriptor: Int32, count: Int, offset: Int) -> (bytes: [UInt8], failure: Int32?) {
        var buffer = [UInt8](repeating: 0, count: count)
        let result = buffer.withUnsafeMutableBytes { raw in
            // pread writes at most raw.count bytes into raw's storage.
            unsafe pread(descriptor, raw.baseAddress, raw.count, off_t(offset))
        }
        if result < 0 { return ([], errno) }
        buffer.removeSubrange(result...)
        return (buffer, nil)
    }

    static func writeAt(_ descriptor: Int32, _ bytes: [UInt8], from start: Int, offset: Int) -> (count: Int, failure: Int32?) {
        let result = bytes.withUnsafeBytes { raw in
            // pwrite reads at most raw.count - start bytes from raw's storage.
            unsafe pwrite(descriptor, raw.baseAddress.map { unsafe $0 + start }, raw.count - start, off_t(offset))
        }
        return result < 0 ? (0, errno) : (result, nil)
    }

    static func fileSize(_ descriptor: Int32) -> (size: Int, failure: Int32?) {
        var info = stat()
        // fstat fills the struct whose address is passed; it lives for the call.
        if unsafe fstat(descriptor, &info) != 0 { return (0, errno) }
        return (Int(info.st_size), nil)
    }

    static func permissionBits(of path: String) -> (bits: UInt16, failure: Int32?) {
        var info = stat()
        // stat fills the struct whose address is passed, and copies the C string
        // of `path`, which lives for the call.
        if unsafe stat(path, &info) != 0 { return (0, errno) }
        return (UInt16(info.st_mode & 0o7777), nil)
    }

    static func linkTarget(of path: String) -> (target: String?, failure: Int32?) {
        var buffer = [CChar](repeating: 0, count: 4096 + 1)
        let length = buffer.withUnsafeMutableBufferPointer { storage in
            // readlink writes at most 4096 bytes into storage (one short of its size)
            // and does not NUL-terminate; the path's C string lives for the call.
            // The buffer is never empty, so it has a base address (Glibc's
            // readlink takes a non-optional pointer).
            unsafe readlink(path, storage.baseAddress!, storage.count - 1)
        }
        if length < 0 { return (nil, errno) }
        let bytes = buffer[..<length].map { UInt8(bitPattern: $0) }
        return (String(decoding: bytes, as: UTF8.self), nil)
    }

    static func changeMode(_ descriptor: Int32, to mode: mode_t) -> Int32 {
        fchmod(descriptor, mode)
    }

    static func truncateFile(_ descriptor: Int32, to size: Int) -> Int32 {
        ftruncate(descriptor, off_t(size))
    }

    #if canImport(Darwin)
    static func fullFsync(_ descriptor: Int32) -> Int32 {
        fcntl(descriptor, F_FULLFSYNC)
    }
    #endif

    static func fsyncFile(_ descriptor: Int32) -> Int32 {
        fsync(descriptor)
    }

    static func lockFile(_ descriptor: Int32, operation: Int32) -> Int32 {
        flock(descriptor, operation)
    }

    static func closeFile(_ descriptor: Int32) -> Int32 {
        close(descriptor)
    }

    static func renamePath(_ source: String, to destination: String) -> Int32 {
        // Both C strings live for the call; rename copies them.
        unsafe rename(source, destination)
    }

    static func exchangePaths(_ first: String, _ second: String) -> Int32 {
        #if canImport(Darwin)
        // Both C strings live for the call; renamex_np copies them.
        unsafe renamex_np(first, second, UInt32(RENAME_SWAP))
        #else
        errno = ENOTSUP
        return -1
        #endif
    }

    /// Whether `path` is itself a directory; a symbolic link to one is not.
    static func isDirectory(_ path: String) -> (isDirectory: Bool, failure: Int32?) {
        var info = stat()
        // lstat fills the struct whose address is passed, and copies the C
        // string of `path`, which lives for the call.
        if unsafe lstat(path, &info) != 0 { return (false, errno) }
        return (info.st_mode & S_IFMT == S_IFDIR, nil)
    }

    static func removeDirectory(_ path: String) -> Int32 {
        unsafe rmdir(path)
    }

    static func unlinkPath(_ path: String) -> Int32 {
        unsafe unlink(path)
    }

    static func accessPath(_ path: String) -> Int32 {
        unsafe access(path, F_OK)
    }

    static func makeDirectory(_ path: String, permissions: mode_t) -> Int32 {
        unsafe mkdir(path, permissions)
    }

    static func availableBytes(_ path: String) -> (bytes: UInt64, failure: Int32?) {
        var info = statvfs()
        // statvfs fills the struct whose address is passed; it lives for the call.
        if unsafe statvfs(path, &info) != 0 { return (0, errno) }
        return (UInt64(info.f_bavail) * UInt64(info.f_frsize), nil)
    }

    static func listDirectory(_ path: String) -> (names: [String], failure: Int32?) {
        guard let directory = unsafe opendir(path) else { return ([], errno) }
        defer { unsafe _ = closedir(directory) }
        var names: [String] = []
        // readdir returns a pointer into the DIR's own buffer, valid until the
        // next readdir or closedir on this DIR; each name is copied into a
        // String before the next call, and d_name is NUL-terminated.
        while let entry = unsafe readdir(directory) {
            let name = unsafe withUnsafePointer(to: &entry.pointee.d_name) { tuple in
                unsafe tuple.withMemoryRebound(to: CChar.self, capacity: 1) { unsafe String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return (names, nil)
    }
}
