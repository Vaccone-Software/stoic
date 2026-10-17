internal import Synchronization

/// An in-memory file system that models what a crash destroys.
///
/// Real file systems lie politely: a `write` that returned has changed what
/// readers see, but not what survives power loss. This one keeps both. Each
/// file has *durable* content and a list of *pending* operations (writes and
/// truncates) that only ``fullSync(_:)`` on that file makes durable.
/// Directory entries — creates, renames, removes — are pending until
/// ``syncDirectory(_:)``. A crash discards whatever is not durable, and in
/// the adversarial form (``crashImages(afterOperation:samples:seed:)``) keeps
/// any subset of it, in any combination, torn at any byte, because that is
/// what hardware is allowed to do.
///
/// Every operation that can matter to durability is appended to
/// ``operations``, and the state after each one is kept, so a test can crash
/// "after the fifth call" without re-running anything:
///
///     let disk = SimulatedFileSystem()
///     try disk.createDirectory("/app")
///     disk.settle()                                  // everything so far is durable
///     try AtomicFile(fileSystem: disk).write(bytes, to: "/app/settings")
///     for point in 0...disk.operationCount {
///         for image in disk.crashImages(afterOperation: point) {
///             // recover from image.fileSystem and check it
///         }
///     }
///
/// A directory made by ``createDirectory(_:)`` is a name in its parent like
/// any other, pending until the parent is synced, which `createDirectory`
/// does before it returns; a crash inside it can lose the directory and
/// everything in it. A failed ``fullSync(_:)`` drops the file's pending
/// writes, as Linux does after a writeback error: readers still see them, and
/// no later sync makes them durable. Paths are `/`-separated strings.
public final class SimulatedFileSystem: FileSystem {
    let state: Mutex<State>

    /// - Parameters:
    ///   - capacity: The volume size in bytes; writes beyond it fail with
    ///     `ENOSPC`. `nil` means unlimited.
    ///   - recordsHistory: Keep the state after every operation so crash
    ///     points can be explored. Turn off for long simulations that never
    ///     look back.
    public init(capacity: Int? = nil, recordsHistory: Bool = true) {
        state = Mutex(State(capacity: capacity, recordsHistory: recordsHistory))
    }

    // MARK: Inspecting

    /// One durability-relevant call, in order.
    public enum Operation: Sendable, Hashable, CustomStringConvertible {
        case create(path: String)
        case write(path: String, offset: Int, count: Int)
        case truncate(path: String, size: Int)
        case fullSync(path: String)
        case createDirectory(path: String)
        case rename(from: String, to: String)
        case exchange(String, String)
        case remove(path: String)
        case syncDirectory(path: String)

        public var description: String {
            switch self {
            case .create(let path): "create \(path)"
            case .write(let path, let offset, let count): "write \(path) [\(offset)..<\(offset + count)]"
            case .truncate(let path, let size): "truncate \(path) to \(size)"
            case .fullSync(let path): "fullSync \(path)"
            case .createDirectory(let path): "createDirectory \(path)"
            case .rename(let from, let to): "rename \(from) -> \(to)"
            case .exchange(let first, let second): "exchange \(first) <-> \(second)"
            case .remove(let path): "remove \(path)"
            case .syncDirectory(let path): "syncDirectory \(path)"
            }
        }
    }

    /// A named position in the operation log, recorded by ``checkpoint(_:)``.
    public struct Checkpoint: Sendable, Hashable {
        public let label: String
        /// The number of operations that had been performed.
        public let operationCount: Int
    }

    /// The operation log: every create, write, truncate, sync, rename and
    /// remove since the last ``settle()``.
    public var operations: [Operation] { state.withLock { $0.operations } }

    /// How many operations are in the log; also the last crash point.
    public var operationCount: Int { state.withLock { $0.operations.count } }

    /// Marks the current position in the log. A test calls this when an
    /// operation under test *returns*, so the invariant "once acknowledged,
    /// durable" knows which crash points come after the acknowledgement.
    public func checkpoint(_ label: String) {
        state.withLock { $0.checkpoints.append(Checkpoint(label: label, operationCount: $0.operations.count)) }
    }

    public var checkpoints: [Checkpoint] { state.withLock { $0.checkpoints } }

    /// The file's current contents (what a reader would see), or `nil`.
    public func contents(of path: String) -> [UInt8]? {
        state.withLock { state in state.live[path].map { state.inodes[$0]!.current } }
    }

    /// The file's contents as they would survive a crash that kept nothing
    /// pending, or `nil` if its name would not survive.
    public func durableContents(of path: String) -> [UInt8]? {
        state.withLock { state in state.durableNames[path].map { state.inodes[$0]!.durable } }
    }

    /// Makes `path` a symbolic link to `target` (relative targets resolve
    /// against the link's directory). Links are modelled as durable the
    /// moment they exist: the store never creates one, so what a crash does
    /// to a pending link never matters, and a crash image keeps them all.
    public func symlink(at path: String, to target: String) {
        state.withLock { $0.links[path] = target }
    }

    /// Every file's current contents, by path.
    public var files: [String: [UInt8]] {
        state.withLock { state in state.live.mapValues { state.inodes[$0]!.current } }
    }

    /// Whether any change is waiting for a sync.
    public var hasPendingChanges: Bool {
        state.withLock { state in
            !state.pendingDirOps.isEmpty || state.inodes.values.contains { !$0.pending.isEmpty }
        }
    }

    // MARK: Crashing

    /// Makes everything so far durable and starts a fresh log: the setup of a
    /// test ends here, and the operation under test begins.
    public func settle() {
        state.withLock { $0.settle() }
    }

    /// Crashes in place, keeping nothing that is not durable. Open files are
    /// gone, as after a reboot. For the other crashes the hardware may
    /// legally produce, use ``crashImages(afterOperation:samples:seed:)``.
    public func crash() {
        state.withLock { state in
            let directories = State.surviving(state.durableDirectories)
            state = State(
                restoring: State.files(state.imageWithNothingPending(), in: directories), modes: state.durableModes(),
                links: state.links, directories: directories, like: state
            )
        }
    }

    /// One way the world can look after a crash.
    public struct CrashImage: Sendable {
        /// The crash point: the number of operations that had completed.
        public let operationCount: Int
        /// What survived and what was lost, in words.
        public let description: String
        /// A fresh file system holding exactly the surviving bytes.
        public let fileSystem: SimulatedFileSystem
    }

    /// The distinct file-system states recovery might find if the machine
    /// died after `operationCount` operations (0 is the state before the
    /// first).
    ///
    /// The set always includes: nothing pending survived; everything did;
    /// every prefix of each file's pending writes; each pending write torn
    /// at byte granularity (every byte for writes up to 96 bytes, sector and
    /// power-of-two boundaries beyond); each write that spans 4 KiB pages
    /// kept page by page (every combination up to four pages, each page alone
    /// missing or kept beyond), the file grown over the missing pages or not;
    /// every subset of the pending directory
    /// operations (all of them up to six, prefixes beyond); those crossed
    /// with each other at their extremes; and `samples` random combinations
    /// of all of it. Images that leave identical files are returned once.
    public func crashImages(afterOperation operationCount: Int, samples: Int = 40, seed: UInt64 = 0) -> [CrashImage] {
        state.withLock { state in
            let snapshot = state.history.indices.contains(operationCount) ? state.history[operationCount] : state
            return Explorer(state: snapshot, samples: samples, seed: seed).images(at: operationCount)
        }
    }

    /// An independent copy of this file system, pending changes and all, with
    /// a fresh history. Lets a test branch: run recovery on a copy of a crash
    /// image and crash *that*.
    public func fork() -> SimulatedFileSystem {
        let copy = state.withLock { $0 }
        let fork = SimulatedFileSystem(capacity: copy.capacity, recordsHistory: copy.recordsHistory)
        fork.state.withLock { $0 = copy.withoutHistoryReset() }
        return fork
    }

    // MARK: Faults

    /// What a scripted fault applies to.
    public enum FaultTarget: Sendable, Hashable {
        case open, read, write, truncate, fullSync, syncDirectory, rename, exchange, remove
    }

    /// Makes matching calls fail with `errno`, leaving the file system as it
    /// was before the call, with one exception, because it is what a real
    /// kernel does: a failed `fullSync` drops the file's pending writes from
    /// durability (they stay visible to readers, and a later sync does not
    /// bring them back), so a caller that retries the sync and trusts the
    /// answer is caught.
    ///
    /// - Parameters:
    ///   - errno: The error number the failing calls report.
    ///   - target: The kind of call to fail.
    ///   - skipping: How many matching calls succeed first.
    ///   - count: How many matching calls fail after that.
    public func inject(_ errno: Int32, on target: FaultTarget, skipping: Int = 0, count: Int = 1) {
        state.withLock { $0.faults.append(Fault(target: target, errno: errno, skip: skipping, remaining: count)) }
    }

    /// Forgets every scripted fault.
    public func clearFaults() {
        state.withLock { $0.faults.removeAll() }
    }

    // MARK: FileSystem

    public func open(_ path: String, mode: OpenMode) throws(StoreError) -> OpenFile {
        try state.withLock { (state) throws(StoreError) in try state.open(path, mode: mode) }
    }

    public func read(_ file: OpenFile, at offset: Int, count: Int) throws(StoreError) -> [UInt8] {
        try state.withLock { (state) throws(StoreError) in try state.read(file, at: offset, count: count) }
    }

    public func write(_ file: OpenFile, _ bytes: [UInt8], at offset: Int) throws(StoreError) {
        try state.withLock { (state) throws(StoreError) in try state.write(file, bytes, at: offset) }
    }

    public func size(of file: OpenFile) throws(StoreError) -> Int {
        try state.withLock { (state) throws(StoreError) in try state.size(of: file) }
    }

    public func truncate(_ file: OpenFile, to size: Int) throws(StoreError) {
        try state.withLock { (state) throws(StoreError) in try state.truncate(file, to: size) }
    }

    public func fullSync(_ file: OpenFile) throws(StoreError) {
        try state.withLock { (state) throws(StoreError) in try state.fullSync(file) }
    }

    public func close(_ file: OpenFile) throws(StoreError) {
        try state.withLock { (state) throws(StoreError) in try state.close(file) }
    }

    public func syncDirectory(_ directory: String) throws(StoreError) {
        try state.withLock { (state) throws(StoreError) in try state.syncDirectory(directory) }
    }

    public func rename(from source: String, to destination: String) throws(StoreError) {
        try state.withLock { (state) throws(StoreError) in try state.rename(from: source, to: destination) }
    }

    public func exchange(_ first: String, _ second: String) throws(StoreError) {
        try state.withLock { (state) throws(StoreError) in try state.exchange(first, second) }
    }

    public func remove(_ path: String) throws(StoreError) {
        try state.withLock { (state) throws(StoreError) in try state.remove(path) }
    }

    public func list(directory: String) throws(StoreError) -> [String] {
        try state.withLock { (state) throws(StoreError) in try state.list(directory) }
    }

    public func exists(_ path: String) throws(StoreError) -> Bool {
        try state.withLock { (state) throws(StoreError) in
            let target = try state.followingLinks(path)
            return state.live[target] != nil || state.directories.contains(target)
        }
    }

    public func readLink(_ path: String) throws(StoreError) -> String? {
        state.withLock { $0.links[path] }
    }

    public func freeSpace(at directory: String) throws(StoreError) -> UInt64 {
        state.withLock { state in
            guard let capacity = state.capacity else { return UInt64.max / 2 }
            return UInt64(max(0, capacity - state.usedBytes))
        }
    }

    public func permissions(of path: String) throws(StoreError) -> UInt16? {
        try state.withLock { (state) throws(StoreError) in
            let target = try state.followingLinks(path)
            return state.live[target].map { state.inodes[$0]!.mode }
        }
    }

    public func setPermissions(_ file: OpenFile, to permissions: UInt16) throws(StoreError) {
        try state.withLock { (state) throws(StoreError) in
            let ino = try state.inode(for: file)
            state.inodes[ino]!.mode = permissions & 0o7777
        }
    }

    public func tryLock(_ file: OpenFile) throws(StoreError) -> Bool {
        try state.withLock { (state) throws(StoreError) in
            let ino = try state.inode(for: file)
            if let holder = state.locks[ino], holder != file.rawValue { return false }
            state.locks[ino] = file.rawValue
            return true
        }
    }

    public func unlock(_ file: OpenFile) throws(StoreError) {
        try state.withLock { (state) throws(StoreError) in
            let ino = try state.inode(for: file)
            if state.locks[ino] == file.rawValue { state.locks[ino] = nil }
        }
    }

    /// Creates `path` and any missing parents, each a pending name in its
    /// parent that is then synced, as `PosixFileSystem` does: durable when
    /// this returns, lost if the machine dies part-way.
    public func createDirectory(_ path: String) throws(StoreError) {
        try state.withLock { (state) throws(StoreError) in
            var prefix = ""
            for component in path.split(separator: "/", omittingEmptySubsequences: true) {
                prefix += "/" + component
                guard !state.directories.contains(prefix) else { continue }
                state.directories.insert(prefix)
                state.pendingDirOps.append(.makeDirectory(path: prefix))
                state.record(.createDirectory(path: prefix))
                try state.syncDirectory(StorePath.directory(of: prefix))
            }
        }
    }
}

// MARK: - State

extension SimulatedFileSystem {
    struct Inode: Sendable {
        var durable: [UInt8] = []
        var current: [UInt8] = []
        var pending: [Pending] = []
        var name: String
        /// The permission bits. Modelled as durable the moment they are set:
        /// the store only sets them on a file it is about to rename into
        /// place, so what a crash could do to a pending `chmod` never matters.
        var mode: UInt16 = 0o644
    }

    enum Pending: Sendable {
        case write(offset: Int, bytes: [UInt8])
        case truncate(size: Int)

        func applied(to content: [UInt8]) -> [UInt8] {
            var result = content
            switch self {
            case .write(let offset, let bytes):
                if result.count < offset + bytes.count {
                    result.append(contentsOf: [UInt8](repeating: 0, count: offset + bytes.count - result.count))
                }
                result.replaceSubrange(offset..<offset + bytes.count, with: bytes)
            case .truncate(let size):
                if result.count > size {
                    result.removeSubrange(size...)
                } else {
                    result.append(contentsOf: [UInt8](repeating: 0, count: size - result.count))
                }
            }
            return result
        }
    }

    enum DirectoryOperation: Sendable {
        case create(path: String, inode: Int)
        case rename(from: String, to: String, inode: Int)
        case exchange(first: String, second: String, firstInode: Int, secondInode: Int)
        case remove(path: String)
        case makeDirectory(path: String)

        var directories: [String] {
            switch self {
            case .create(let path, _), .remove(let path), .makeDirectory(let path): [StorePath.directory(of: path)]
            case .rename(let from, let to, _): [StorePath.directory(of: from), StorePath.directory(of: to)]
            case .exchange(let first, let second, _, _): [StorePath.directory(of: first), StorePath.directory(of: second)]
            }
        }

        /// Applies this operation to a name table. A rename is bound to its
        /// inode, not to the name it came from: the entry for the new name
        /// appears whether or not the entry for the old name ever became
        /// durable, which is the harsher of the two readings.
        func apply(to names: inout [String: Int]) {
            switch self {
            case .create(let path, let inode): names[path] = inode
            case .rename(let from, let to, let inode):
                if names[from] == inode { names[from] = nil }
                names[to] = inode
            case .exchange(let first, let second, let firstInode, let secondInode):
                // One atomic step: each name now leads to the other's inode.
                names[first] = secondInode
                names[second] = firstInode
            case .remove(let path): names[path] = nil
            case .makeDirectory: break
            }
        }

        /// Applies this operation to a set of directories.
        func apply(to directories: inout Set<String>) {
            if case .makeDirectory(let path) = self { directories.insert(path) }
        }
    }

    struct Fault: Sendable {
        let target: FaultTarget
        let errno: Int32
        var skip: Int
        var remaining: Int
    }

    struct State: Sendable {
        var inodes: [Int: Inode] = [:]
        var live: [String: Int] = [:]
        var durableNames: [String: Int] = [:]
        var pendingDirOps: [DirectoryOperation] = []
        var directories: Set<String> = []
        /// The directories that would survive a crash that kept nothing pending.
        var durableDirectories: Set<String> = []
        var links: [String: String] = [:]
        var descriptors: [Int32: Int] = [:]
        /// The open file (descriptor) holding each inode's advisory lock.
        /// Closing the file drops it; a crash starts with none, as a reboot does.
        var locks: [Int: Int32] = [:]
        var nextInode = 1
        var nextDescriptor: Int32 = 3
        var operations: [Operation] = []
        var checkpoints: [Checkpoint] = []
        var history: [State] = []
        var faults: [Fault] = []
        let capacity: Int?
        let recordsHistory: Bool

        init(capacity: Int?, recordsHistory: Bool) {
            self.capacity = capacity
            self.recordsHistory = recordsHistory
            if recordsHistory { history = [withoutHistory()] }
        }

        /// A state restored from a crash image's files.
        init(restoring files: [String: [UInt8]], modes: [String: UInt16] = [:], links: [String: String], directories: Set<String>, like other: State) {
            self.links = links
            capacity = other.capacity
            recordsHistory = other.recordsHistory
            self.directories = directories
            durableDirectories = directories
            for path in files.keys.sorted() {
                let inode = nextInode
                nextInode += 1
                inodes[inode] = Inode(durable: files[path]!, current: files[path]!, name: path, mode: modes[path] ?? 0o644)
                live[path] = inode
                durableNames[path] = inode
            }
            if recordsHistory { history = [withoutHistory()] }
        }

        func withoutHistoryReset() -> State {
            var copy = self
            copy.operations = []
            copy.checkpoints = []
            copy.history = recordsHistory ? [withoutHistory()] : []
            return copy
        }

        func withoutHistory() -> State {
            var copy = self
            copy.history = []
            return copy
        }

        var usedBytes: Int { live.values.reduce(0) { $0 + inodes[$1]!.current.count } }

        mutating func settle() {
            for key in inodes.keys {
                inodes[key]!.durable = inodes[key]!.current
                inodes[key]!.pending = []
            }
            durableNames = live
            durableDirectories = directories
            pendingDirOps = []
            operations = []
            checkpoints = []
            history = recordsHistory ? [withoutHistory()] : []
        }

        /// The files that would exist if nothing pending survived.
        func durableModes() -> [String: UInt16] {
            durableNames.mapValues { inodes[$0]!.mode }
        }

        func imageWithNothingPending() -> [String: [UInt8]] {
            durableNames.mapValues { inodes[$0]!.durable }
        }

        /// `directories` without any whose parent did not survive: a
        /// directory whose own name survived inside a lost one is lost too.
        static func surviving(_ directories: Set<String>) -> Set<String> {
            var kept: Set<String> = []
            for directory in directories.sorted(by: { $0.count < $1.count }) {
                let parent = StorePath.directory(of: directory)
                if parent == "/" || parent == "." || kept.contains(parent) { kept.insert(directory) }
            }
            return kept
        }

        /// The files whose directory is among `directories`.
        static func files<V>(_ files: [String: V], in directories: Set<String>) -> [String: V] {
            files.filter { path, _ in
                let parent = StorePath.directory(of: path)
                return parent == "/" || parent == "." || directories.contains(parent)
            }
        }

        mutating func record(_ operation: Operation) {
            operations.append(operation)
            if recordsHistory { history.append(withoutHistory()) }
        }

        mutating func checkFault(_ target: FaultTarget, path: String? = nil) throws(StoreError) {
            guard let index = faults.firstIndex(where: { $0.target == target && $0.remaining > 0 }) else { return }
            if faults[index].skip > 0 {
                faults[index].skip -= 1
                return
            }
            faults[index].remaining -= 1
            throw StoreError(errno: faults[index].errno, operation: "\(target)", path: path)
        }

        /// `path` with a symbolic link as its last component replaced by what
        /// it points to, repeatedly: what `open` and `access` do.
        func followingLinks(_ path: String) throws(StoreError) -> String {
            var current = path
            for _ in 0..<40 {
                guard let target = links[current] else { return current }
                current = target.hasPrefix("/") ? target : StorePath.join(StorePath.directory(of: current), target)
            }
            throw StoreError(errno: ELOOP_, operation: "open", path: path)
        }

        func parentExists(_ path: String) -> Bool {
            let parent = StorePath.directory(of: path)
            return parent == "." || parent == "/" || directories.contains(parent)
        }

        mutating func open(_ requested: String, mode: OpenMode) throws(StoreError) -> OpenFile {
            try checkFault(.open, path: requested)
            // O_EXCL refuses a symbolic link as the final component; every
            // other mode follows it.
            if mode == .createExclusive, links[requested] != nil { throw StoreError(errno: EEXIST_, operation: "open", path: requested) }
            let path = try followingLinks(requested)
            guard parentExists(path) else { throw StoreError(errno: ENOENT_, operation: "open", path: path) }
            let inode: Int
            if let existing = live[path] {
                if mode == .createExclusive { throw StoreError(errno: EEXIST_, operation: "open", path: path) }
                inode = existing
            } else {
                guard mode == .createExclusive || mode == .readWriteCreate else {
                    throw StoreError(errno: ENOENT_, operation: "open", path: path)
                }
                inode = nextInode
                nextInode += 1
                inodes[inode] = Inode(name: path)
                live[path] = inode
                pendingDirOps.append(.create(path: path, inode: inode))
                record(.create(path: path))
            }
            let descriptor = nextDescriptor
            nextDescriptor += 1
            descriptors[descriptor] = inode
            return OpenFile(rawValue: descriptor)
        }

        func inode(for file: OpenFile) throws(StoreError) -> Int {
            guard let inode = descriptors[file.rawValue] else {
                throw StoreError(kind: .invalidArgument, operation: "fd", errnoValue: EBADF_, detail: "\(file) is not open")
            }
            return inode
        }

        mutating func read(_ file: OpenFile, at offset: Int, count: Int) throws(StoreError) -> [UInt8] {
            let ino = try inode(for: file)
            try checkFault(.read, path: inodes[ino]!.name)
            let content = inodes[ino]!.current
            guard offset < content.count, count > 0 else { return [] }
            return Array(content[offset..<min(content.count, offset + count)])
        }

        mutating func write(_ file: OpenFile, _ bytes: [UInt8], at offset: Int) throws(StoreError) {
            let ino = try inode(for: file)
            try checkFault(.write, path: inodes[ino]!.name)
            guard !bytes.isEmpty else { return }
            if let capacity {
                let growth = max(0, offset + bytes.count - inodes[ino]!.current.count)
                if usedBytes + growth > capacity { throw StoreError(errno: ENOSPC_, operation: "write", path: inodes[ino]!.name) }
            }
            let operation = Pending.write(offset: offset, bytes: bytes)
            inodes[ino]!.current = operation.applied(to: inodes[ino]!.current)
            inodes[ino]!.pending.append(operation)
            record(.write(path: inodes[ino]!.name, offset: offset, count: bytes.count))
        }

        mutating func size(of file: OpenFile) throws(StoreError) -> Int {
            inodes[try inode(for: file)]!.current.count
        }

        mutating func truncate(_ file: OpenFile, to size: Int) throws(StoreError) {
            let ino = try inode(for: file)
            try checkFault(.truncate, path: inodes[ino]!.name)
            let operation = Pending.truncate(size: size)
            inodes[ino]!.current = operation.applied(to: inodes[ino]!.current)
            inodes[ino]!.pending.append(operation)
            record(.truncate(path: inodes[ino]!.name, size: size))
        }

        mutating func fullSync(_ file: OpenFile) throws(StoreError) {
            let ino = try inode(for: file)
            do throws(StoreError) {
                try checkFault(.fullSync, path: inodes[ino]!.name)
            } catch {
                // The kernel may have marked the dirty pages clean: readers
                // still see the writes, but they will never reach the disk.
                inodes[ino]!.pending = []
                throw error
            }
            // What was pending, not what readers see: writes an earlier failed
            // sync dropped are not made durable by this one.
            inodes[ino]!.durable = inodes[ino]!.pending.reduce(inodes[ino]!.durable) { $1.applied(to: $0) }
            inodes[ino]!.pending = []
            record(.fullSync(path: inodes[ino]!.name))
        }

        mutating func close(_ file: OpenFile) throws(StoreError) {
            let ino = try inode(for: file)
            if locks[ino] == file.rawValue { locks[ino] = nil }
            descriptors[file.rawValue] = nil
        }

        mutating func syncDirectory(_ directory: String) throws(StoreError) {
            try checkFault(.syncDirectory, path: directory)
            let normalized = directory == "/" ? "/" : directory
            var remaining: [DirectoryOperation] = []
            for operation in pendingDirOps {
                if operation.directories.contains(normalized) {
                    operation.apply(to: &durableNames)
                    operation.apply(to: &durableDirectories)
                } else {
                    remaining.append(operation)
                }
            }
            pendingDirOps = remaining
            record(.syncDirectory(path: directory))
        }

        mutating func rename(from source: String, to destination: String) throws(StoreError) {
            try checkFault(.rename, path: source)
            guard parentExists(destination) else { throw StoreError(errno: ENOENT_, operation: "rename", path: destination) }
            if live[source] == nil, let link = links[source] {
                // A rename moves the link itself, never what it points to.
                links[source] = nil
                links[destination] = link
                live[destination] = nil
                return
            }
            guard let ino = live[source] else { throw StoreError(errno: ENOENT_, operation: "rename", path: source) }
            // Renaming over a symbolic link replaces the link, not its target.
            links[destination] = nil
            live[source] = nil
            live[destination] = ino
            inodes[ino]!.name = destination
            pendingDirOps.append(.rename(from: source, to: destination, inode: ino))
            record(.rename(from: source, to: destination))
        }

        mutating func exchange(_ first: String, _ second: String) throws(StoreError) {
            try checkFault(.exchange, path: first)
            // Only files are modelled, so only files can be swapped.
            guard let firstInode = live[first], let secondInode = live[second] else {
                throw StoreError(errno: ENOENT_, operation: "renamex_np", path: live[first] == nil ? first : second)
            }
            live[first] = secondInode
            live[second] = firstInode
            inodes[firstInode]!.name = second
            inodes[secondInode]!.name = first
            pendingDirOps.append(.exchange(first: first, second: second, firstInode: firstInode, secondInode: secondInode))
            record(.exchange(first, second))
        }

        mutating func remove(_ path: String) throws(StoreError) {
            try checkFault(.remove, path: path)
            if live[path] == nil, links[path] != nil {
                links[path] = nil
                return
            }
            guard live[path] != nil else { throw StoreError(errno: ENOENT_, operation: "unlink", path: path) }
            live[path] = nil
            pendingDirOps.append(.remove(path: path))
            record(.remove(path: path))
        }

        mutating func list(_ directory: String) throws(StoreError) -> [String] {
            guard directory == "." || directory == "/" || directories.contains(directory) else {
                throw StoreError(errno: ENOENT_, operation: "readdir", path: directory)
            }
            return (Array(live.keys) + Array(links.keys)).filter { StorePath.directory(of: $0) == directory }.map(StorePath.name(of:)).sorted()
        }
    }
}

#if canImport(Darwin)
internal import Darwin
#elseif canImport(Glibc)
internal import Glibc
#endif

// errno values under names that do not shadow anything inside `State`.
private let ENOENT_ = ENOENT
private let EEXIST_ = EEXIST
private let EBADF_ = EBADF
private let ENOSPC_ = ENOSPC
private let ELOOP_ = ELOOP
