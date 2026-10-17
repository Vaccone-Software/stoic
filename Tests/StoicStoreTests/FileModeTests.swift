import Foundation
import Stoic
@testable import StoicStore
import StoicTesting
import Testing

/// A real file system that looks at every file the instant `open` hands it
/// back, before the store has done anything else with it, and records every
/// `fchmod`: the two things that tell "created private" from "created open,
/// then made private".
private final class CreationProbe: FileSystem {
    struct Creation: Sendable, Hashable {
        let path: String
        let mode: UInt16
    }

    private let base: PosixFileSystem
    private let seen = SendableBox<[Creation]>([])
    private let modeChanges = SendableBox<[UInt16]>([])

    init(_ base: PosixFileSystem) { self.base = base }

    /// Each file created, with its bits as they were when `open` returned.
    var creations: [Creation] { seen.value }
    var changes: [UInt16] { modeChanges.value }
    var newFileMode: UInt16 { base.newFileMode }

    func open(_ path: String, mode: OpenMode) throws(StoreError) -> OpenFile {
        let existed = try base.exists(path)
        let file = try base.open(path, mode: mode)
        if !existed, mode != .read, mode != .readWrite {
            let bits = (try? base.permissions(of: path)).flatMap { $0 } ?? 0
            seen.mutate { $0.append(Creation(path: path, mode: bits)) }
        }
        return file
    }

    func setPermissions(_ file: OpenFile, to permissions: UInt16) throws(StoreError) {
        modeChanges.mutate { $0.append(permissions) }
        try base.setPermissions(file, to: permissions)
    }

    func createDirectory(_ path: String) throws(StoreError) { try base.createDirectory(path) }
    func read(_ file: OpenFile, at offset: Int, count: Int) throws(StoreError) -> [UInt8] { try base.read(file, at: offset, count: count) }
    func write(_ file: OpenFile, _ bytes: [UInt8], at offset: Int) throws(StoreError) { try base.write(file, bytes, at: offset) }
    func size(of file: OpenFile) throws(StoreError) -> Int { try base.size(of: file) }
    func truncate(_ file: OpenFile, to size: Int) throws(StoreError) { try base.truncate(file, to: size) }
    func fullSync(_ file: OpenFile) throws(StoreError) { try base.fullSync(file) }
    func close(_ file: OpenFile) throws(StoreError) { try base.close(file) }
    func syncDirectory(_ directory: String) throws(StoreError) { try base.syncDirectory(directory) }
    func rename(from source: String, to destination: String) throws(StoreError) { try base.rename(from: source, to: destination) }
    func remove(_ path: String) throws(StoreError) { try base.remove(path) }
    func list(directory: String) throws(StoreError) -> [String] { try base.list(directory: directory) }
    func exists(_ path: String) throws(StoreError) -> Bool { try base.exists(path) }
    func freeSpace(at directory: String) throws(StoreError) -> UInt64 { try base.freeSpace(at: directory) }
    func permissions(of path: String) throws(StoreError) -> UInt16? { try base.permissions(of: path) }
    func tryLock(_ file: OpenFile) throws(StoreError) -> Bool { try base.tryLock(file) }
    func unlock(_ file: OpenFile) throws(StoreError) { try base.unlock(file) }
}

@Suite("File modes")
struct FileModeTests {
    let privateDisk = PosixFileSystem(newFileMode: 0o600, newDirectoryMode: 0o700)

    @Test(.failureMode("design/15", "a file is created through a file system asked for private files"))
    func aNewFileHasTheRequestedModeTheInstantItExists() throws {
        let dir = try TempDirectory()
        for (index, mode) in [OpenMode.createExclusive, .readWriteCreate].enumerated() {
            let path = dir.file("created-\(index)")
            let file = try privateDisk.open(path, mode: mode)
            // Straight after the create, nothing written, nothing changed.
            #expect(try privateDisk.permissions(of: path) == 0o600)
            try privateDisk.close(file)
        }
        // Reopening is not creating: the bits are not touched.
        let path = dir.file("existing")
        let shared = PosixFileSystem(newFileMode: 0o640)
        try shared.close(try shared.open(path, mode: .createExclusive))
        try privateDisk.close(try privateDisk.open(path, mode: .readWriteCreate))
        #expect(try privateDisk.permissions(of: path) == 0o640)
    }

    @Test(.failureMode("design/15", "a directory is created through a file system asked for private directories"))
    func everyDirectoryItMakesHasTheRequestedModeAndOnesThatExistAreLeftAlone() throws {
        let dir = try TempDirectory()
        // `dir` itself was made by FileManager: it is not ours to change.
        let before = try privateDisk.permissions(of: dir.path)
        try privateDisk.createDirectory(dir.file("a/b/c"))
        #expect(try privateDisk.permissions(of: dir.file("a")) == 0o700)
        #expect(try privateDisk.permissions(of: dir.file("a/b")) == 0o700)
        #expect(try privateDisk.permissions(of: dir.file("a/b/c")) == 0o700)
        #expect(try privateDisk.permissions(of: dir.path) == before)
        // An existing directory with other bits keeps them when a deeper one is added.
        try PosixFileSystem(newDirectoryMode: 0o750).createDirectory(dir.file("x"))
        try privateDisk.createDirectory(dir.file("x/y"))
        #expect(try privateDisk.permissions(of: dir.file("x")) == 0o750)
        #expect(try privateDisk.permissions(of: dir.file("x/y")) == 0o700)
    }

    @Test func theDefaultsAreWhatTheyWereAndTheUmaskOnlyNarrowsThem() throws {
        let defaults = PosixFileSystem()
        #expect(defaults.newFileMode == 0o644 && defaults.newDirectoryMode == 0o755)
        let dir = try TempDirectory()
        try defaults.close(try defaults.open(dir.file("f"), mode: .createExclusive))
        try defaults.createDirectory(dir.file("d"))
        let file = try #require(try defaults.permissions(of: dir.file("f")))
        let directory = try #require(try defaults.permissions(of: dir.file("d")))
        // 0o644 and 0o755 under the usual umask; a stricter one removes bits, nothing adds them.
        #expect(file & ~0o644 == 0 && file & 0o600 == 0o600)
        #expect(directory & ~0o755 == 0 && directory & 0o700 == 0o700)
    }

    @Test(.failureMode("design/15", "a journal or an outbox is opened on a private file system"))
    func aJournalAndItsSnapshotAndLockAreCreatedPrivateWithoutAChmod() throws {
        let dir = try TempDirectory()
        let probe = CreationProbe(privateDisk)
        let store = dir.file("store")
        try probe.createDirectory(store)
        let journal = try Journal.open(
            at: store + "/log", fileSystem: probe, options: .init(crossProcessLock: true))
        for index in 0..<4 { try journal.append(bytes("record \(index)")) }
        try journal.compact(snapshot: bytes("folded"))
        try journal.close()

        let created = Set(probe.creations.map(\.path))
        // The log, its lock, and the snapshot's temporary (compaction writes
        // the snapshot with AtomicFile).
        #expect(created.isSuperset(of: [store + "/log", store + "/log.lock", store + "/log.snapshot.tmp"]))
        #expect(probe.creations.allSatisfy { $0.mode == 0o600 })
        // The journal and the lock never change a mode; the snapshot's AtomicFile sets the one the
        // file system gave it, exactly, and nothing wider.
        #expect(probe.changes.allSatisfy { $0 == 0o600 })
        for name in try probe.list(directory: store) {
            #expect(try probe.permissions(of: store + "/" + name) == 0o600, "\(name)")
        }
        #expect(try probe.permissions(of: store) == 0o700)
    }

    @Test(.failureMode("design/15", "a journal or an outbox is opened on a private file system"))
    func anOutboxOnAPrivateFileSystemKeepsEveryFilePrivateThroughDeliveryAndCompaction() async throws {
        let dir = try TempDirectory()
        let store = dir.file("outbox")
        try privateDisk.createDirectory(store)
        let outbox = try Outbox<String>.open(
            at: store + "/queue", codec: .utf8, fileSystem: privateDisk,
            compactionThreshold: 0, journalOptions: .init(crossProcessLock: true))
        try await outbox.enqueue("one")
        try await outbox.enqueue("two")
        let report = try await withTestAmbient(clock: ImmediateClock()) {
            try await outbox.deliverPending { _ in }
        }
        #expect(report.delivered.count == 2)
        try await outbox.close()
        let names = try privateDisk.list(directory: store)
        #expect(names.contains("queue") && names.contains("queue.lock"))
        for name in names {
            #expect(try privateDisk.permissions(of: store + "/" + name) == 0o600, "\(name)")
        }
    }

    @Test(.failureMode("design/15", "an AtomicFile write names no mode"))
    func anAtomicFileThatNamesNoModeTakesTheFileSystemsAndIsPrivateFromTheCreate() throws {
        let dir = try TempDirectory()
        let probe = CreationProbe(privateDisk)
        try AtomicFile(fileSystem: probe).write(bytes("secret"), to: dir.file("s"))
        #expect(probe.creations == [.init(path: dir.file("s.tmp"), mode: 0o600)])
        #expect(probe.changes == [0o600])
        #expect(try probe.permissions(of: dir.file("s")) == 0o600)
        // The default file system is unchanged: 0o644, set exactly, whatever the umask.
        try AtomicFile().write(bytes("plain"), to: dir.file("p"))
        #expect(try PosixFileSystem().permissions(of: dir.file("p")) == 0o644)
    }

    @Test(.failureMode("design/15", "an AtomicFile write names a mode of its own"))
    func aModeNamedInTheOptionsIsAppliedExactlyAndAnExistingFileKeepsItsBits() throws {
        let dir = try TempDirectory()
        try AtomicFile(fileSystem: privateDisk, options: .init(newFileMode: 0o640)).write(bytes("shared"), to: dir.file("t"))
        #expect(try privateDisk.permissions(of: dir.file("t")) == 0o640)
        // A replacement keeps what the file had, whatever the file system or the options say.
        try AtomicFile(fileSystem: privateDisk).write(bytes("again"), to: dir.file("t"))
        #expect(try privateDisk.permissions(of: dir.file("t")) == 0o640)
    }

    @Test func theSimulationHonoursItsFileModeToo() throws {
        let disk = SimulatedFileSystem(newFileMode: 0o600)
        try disk.createDirectory("/d")
        try AtomicFile(fileSystem: disk).write(bytes("x"), to: "/d/a")
        #expect(try disk.permissions(of: "/d/a") == 0o600)
        let journal = try Journal.open(at: "/d/log", fileSystem: disk)
        try journal.append(bytes("r"))
        #expect(try disk.permissions(of: "/d/log") == 0o600)
    }
}
