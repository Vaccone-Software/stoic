#if STOIC_CRYPTO
internal import StoicStore

/// Path arithmetic on `/`-separated strings.
enum Paths {
    /// The directory part: everything before the last `/` (`"."` if none).
    static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "." }
        if slash == path.startIndex { return "/" }
        return String(path[..<slash])
    }

    static func name(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    static func join(_ directory: String, _ name: String) -> String {
        if directory == "." { return name }
        return directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }
}

/// The file operations a download makes, each throwing the downloader's own
/// ``Stop`` instead of `StoreError`, so that every step of the transfer is
/// typed by one error and a failing disk reads as ``DownloadError/store(_:)``.
struct Disk: Sendable {
    let fileSystem: any FileSystem

    private func run<Value>(_ body: () throws(StoreError) -> Value) throws(Stop) -> Value {
        do throws(StoreError) {
            return try body()
        } catch {
            throw Stop(error)
        }
    }

    func open(_ path: String, _ mode: OpenMode) throws(Stop) -> OpenFile {
        try run { () throws(StoreError) in try fileSystem.open(path, mode: mode) }
    }

    func read(_ file: OpenFile, at offset: Int, count: Int) throws(Stop) -> [UInt8] {
        try run { () throws(StoreError) in try fileSystem.read(file, at: offset, count: count) }
    }

    func write(_ file: OpenFile, _ bytes: [UInt8], at offset: Int) throws(Stop) {
        try run { () throws(StoreError) in try fileSystem.write(file, bytes, at: offset) }
    }

    func size(of file: OpenFile) throws(Stop) -> Int {
        try run { () throws(StoreError) in try fileSystem.size(of: file) }
    }

    func truncate(_ file: OpenFile, to size: Int) throws(Stop) {
        try run { () throws(StoreError) in try fileSystem.truncate(file, to: size) }
    }

    func fullSync(_ file: OpenFile) throws(Stop) {
        try run { () throws(StoreError) in try fileSystem.fullSync(file) }
    }

    /// Feeds the first `count` bytes of `file` to `hasher`, a block at a time.
    /// Returns `false` if the file turns out to be shorter than that.
    ///
    /// A 20 GB file is thousands of blocking reads: the task yields between
    /// some of them so other work is not starved, and is cancelled between
    /// them, `Stop.cancellation` being what a cancelled task stops with.
    func hash(
        _ file: OpenFile, count: Int, into hasher: inout ContentHasher, progress: (Int) -> Void
    ) async throws(Stop) -> Bool {
        var position = 0
        var blocks = 0
        while position < count {
            if Task.isCancelled { throw Stop.cancellation }
            let block = try read(file, at: position, count: min(1 << 20, count - position))
            guard !block.isEmpty else { return false }
            hasher.update(block)
            position += block.count
            blocks += 1
            progress(position)
            if blocks % 16 == 0 { await Task.yield() }
        }
        return true
    }

    func close(_ file: OpenFile) throws(Stop) {
        try run { () throws(StoreError) in try fileSystem.close(file) }
    }

    /// Closes `file` and throws `failure`, if there is one: what stopped the
    /// work on the file is the error to report, not one from closing it.
    func close(_ file: OpenFile, after failure: Stop?) throws(Stop) {
        do throws(Stop) {
            try close(file)
        } catch {
            throw failure ?? error
        }
        if let failure { throw failure }
    }

    /// The size of the file at `path`, or `nil` if there is none.
    func size(ofFileAt path: String) throws(Stop) -> Int? {
        guard try exists(path) else { return nil }
        let file = try open(path, .read)
        var size = 0
        var failure: Stop?
        do throws(Stop) {
            size = try self.size(of: file)
        } catch {
            failure = error
        }
        try close(file, after: failure)
        return size
    }

    func setPermissions(_ file: OpenFile, to mode: UInt16) throws(Stop) {
        try run { () throws(StoreError) in try fileSystem.setPermissions(file, to: mode) }
    }

    func exists(_ path: String) throws(Stop) -> Bool {
        try run { () throws(StoreError) in try fileSystem.exists(path) }
    }

    func rename(from source: String, to destination: String) throws(Stop) {
        try run { () throws(StoreError) in try fileSystem.rename(from: source, to: destination) }
    }

    func createDirectory(_ path: String) throws(Stop) {
        try run { () throws(StoreError) in try fileSystem.createDirectory(path) }
    }

    func syncDirectory(_ directory: String) throws(Stop) {
        try run { () throws(StoreError) in try fileSystem.syncDirectory(directory) }
    }

    /// Bytes free on the volume holding `directory`, or `nil` if the volume
    /// cannot say: not a reason to refuse a download.
    func freeSpace(at directory: String) -> UInt64? {
        do throws(StoreError) {
            return try fileSystem.freeSpace(at: directory)
        } catch {
            return nil
        }
    }

    /// Removes the file at `path` if there is one.
    func removeIfPresent(_ path: String) throws(Stop) {
        try run { () throws(StoreError) in
            if try fileSystem.exists(path) { try fileSystem.removeTree(path) }
        }
    }

    /// The names in the directory at `path`, or `nil` if `path` is not a
    /// directory (or is not there).
    func entries(of path: String) throws(Stop) -> [String]? {
        do throws(StoreError) {
            return try fileSystem.list(directory: path)
        } catch where error.kind == .notFound {
            return nil
        } catch {
            throw Stop(error)
        }
    }

    // MARK: Whole small files, atomically

    /// What reading a record found.
    enum Record {
        case missing
        case found([UInt8])
        /// A file was there and failed its checksum: `AtomicFile` has moved it aside.
        case corrupt
    }

    private var records: AtomicFile {
        AtomicFile(fileSystem: fileSystem, options: .init(envelope: true, keepPrevious: false, checksFreeSpace: false, newFileMode: 0o600))
    }

    func readRecord(_ path: String) throws(Stop) -> Record {
        do throws(StoreError) {
            guard let contents = try records.read(path) else { return .missing }
            return .found(contents.bytes)
        } catch where error.kind == .corrupt {
            return .corrupt
        } catch {
            throw Stop(error)
        }
    }

    /// Writes `bytes` to `path` durably and atomically. Returns `false` when
    /// the file is in place but its directory sync failed
    /// (`StoreError.Kind.durabilityUnknown`): for a record that is no loss
    /// (the next run reads what is there), and the caller reports it.
    func writeRecord(_ bytes: [UInt8], to path: String) throws(Stop) -> Bool {
        do throws(StoreError) {
            try records.write(bytes, to: path)
            return true
        } catch where error.kind == .durabilityUnknown {
            return false
        } catch {
            throw Stop(error)
        }
    }

    /// Replaces the item at `destination` with the one at `staged`, as
    /// `AtomicFile.replaceItem` does. Returns `false` when it was replaced but
    /// the sync that makes the swap durable failed.
    func replaceItem(at destination: String, withItemAt staged: String) throws(Stop) -> Bool {
        do throws(StoreError) {
            try AtomicFile(fileSystem: fileSystem).replaceItem(at: destination, withItemAt: staged)
            return true
        } catch where error.kind == .durabilityUnknown {
            return false
        } catch {
            throw Stop(error)
        }
    }
}
#endif
