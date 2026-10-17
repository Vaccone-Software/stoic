import Foundation
import Stoic
@testable import StoicStore
import StoicTesting
import Testing

/// A simulated disk seen through a wrapper that can run code when a file is
/// removed, and can pretend to have no advisory locks.
private final class WatchedDisk: FileSystem {
    let base: SimulatedFileSystem
    let locks: Bool
    let onRemove: @Sendable (String) -> Void

    init(_ base: SimulatedFileSystem, locks: Bool = true, onRemove: @escaping @Sendable (String) -> Void = { _ in }) {
        self.base = base
        self.locks = locks
        self.onRemove = onRemove
    }

    var newFileMode: UInt16 { base.newFileMode }
    func open(_ path: String, mode: OpenMode) throws(StoreError) -> OpenFile { try base.open(path, mode: mode) }
    func read(_ file: OpenFile, at offset: Int, count: Int) throws(StoreError) -> [UInt8] { try base.read(file, at: offset, count: count) }
    func write(_ file: OpenFile, _ bytes: [UInt8], at offset: Int) throws(StoreError) { try base.write(file, bytes, at: offset) }
    func size(of file: OpenFile) throws(StoreError) -> Int { try base.size(of: file) }
    func truncate(_ file: OpenFile, to size: Int) throws(StoreError) { try base.truncate(file, to: size) }
    func fullSync(_ file: OpenFile) throws(StoreError) { try base.fullSync(file) }
    func close(_ file: OpenFile) throws(StoreError) { try base.close(file) }
    func syncDirectory(_ directory: String) throws(StoreError) { try base.syncDirectory(directory) }
    func rename(from source: String, to destination: String) throws(StoreError) { try base.rename(from: source, to: destination) }
    func remove(_ path: String) throws(StoreError) {
        onRemove(path)
        try base.remove(path)
    }
    func list(directory: String) throws(StoreError) -> [String] { try base.list(directory: directory) }
    func exists(_ path: String) throws(StoreError) -> Bool { try base.exists(path) }
    func freeSpace(at directory: String) throws(StoreError) -> UInt64 { try base.freeSpace(at: directory) }
    func createDirectory(_ path: String) throws(StoreError) { try base.createDirectory(path) }
    func permissions(of path: String) throws(StoreError) -> UInt16? { try base.permissions(of: path) }
    func setPermissions(_ file: OpenFile, to permissions: UInt16) throws(StoreError) { try base.setPermissions(file, to: permissions) }
    func tryLock(_ file: OpenFile) throws(StoreError) -> Bool {
        guard locks else { throw StoreError(kind: .unsupported, operation: "flock", detail: "no locks here") }
        return try base.tryLock(file)
    }
    func unlock(_ file: OpenFile) throws(StoreError) { try base.unlock(file) }
}

@Suite("Journal.remove")
struct JournalRemoveTests {
    static let path = "/d/j"

    /// Files that sit beside a journal called `j` and are not its own.
    static let bystanders = [
        "/d/j.bak", "/d/j2", "/d/jb", "/d/xj", "/d/other.snapshot", "/d/j.snapshot.bak", "/d/j.corrupt-x", "/d/j.corrupt-",
        "/d/j.lockfile", "/d/j.snapshot-lost.bak", "/d/j.snapshot.corrupt-", "/d/j.snapshot.tmp.old", "/d/j.tmp",
    ]

    static func disk() throws -> SimulatedFileSystem {
        let disk = SimulatedFileSystem()
        try disk.createDirectory("/d")
        return disk
    }

    static func plant(_ names: [String], on disk: SimulatedFileSystem) throws {
        for name in names {
            let file = try disk.open(name, mode: .createExclusive)
            try disk.write(file, bytes("keep me: " + name), at: 0)
            try disk.fullSync(file)
            try disk.close(file)
        }
        try disk.syncDirectory("/d")
    }

    /// An ordinary journal that has compacted twice and been closed: the log,
    /// the snapshot, the lock file.
    static func ordinary(_ disk: SimulatedFileSystem) throws {
        let journal = try Journal.open(at: path, fileSystem: disk, options: .init(crossProcessLock: true))
        try journal.append(batch: [bytes("a"), bytes("b")])
        try journal.compact(snapshot: bytes("a|b"))
        try journal.append(bytes("c"))
        try journal.compact(snapshot: bytes("a|b|c"))
        try journal.append(bytes("d"))
        try journal.close()
    }

    /// A journal that has been through damage: a log with a flipped byte in
    /// the middle that a compaction copied aside (`.corrupt-1`), then a snapshot
    /// that failed its checksum (quarantined, its loss recorded in a tombstone).
    static func damaged(_ disk: SimulatedFileSystem) throws {
        var journal = try Journal.open(at: path, fileSystem: disk, options: .init(crossProcessLock: true))
        var starts: [Int] = []
        for item in ["a", "b", "c", "d", "e"] {
            starts.append(journal.byteCount)
            try journal.append(bytes(item))
        }
        try journal.close()
        try flipBit(in: path, at: starts[1] + 16, using: disk)
        journal = try Journal.open(at: path, fileSystem: disk, options: .init(crossProcessLock: true))
        try journal.compact(snapshot: bytes("folded"))
        try journal.append(bytes("f"))
        try journal.close()
        try flipBit(in: path + ".snapshot", at: 25, using: disk)
        #expect(throws: StoreError.self) { try Journal.open(at: path, fileSystem: disk, options: .init(crossProcessLock: true)) }
    }

    static func familyOnDisk(_ disk: SimulatedFileSystem) -> [String] {
        disk.files.keys.filter { ($0 == path || $0.hasPrefix(path + ".")) && !bystanders.contains($0) }.sorted()
    }

    // MARK: What goes

    @Test(.failureMode("design/15", "a journal is removed"))
    func theWholeFamilyGoesAndNothingElseDoes() throws {
        for (label, build) in [("ordinary", Self.ordinary), ("damaged", Self.damaged)] {
            let disk = try Self.disk()
            try build(disk)
            try Self.plant(Self.bystanders, on: disk)
            // What a crash can leave beside the files themselves.
            try Self.plant([Self.path + ".snapshot.tmp", Self.path + ".snapshot-lost.tmp", Self.path + ".corrupt-7.tmp"], on: disk)
            let family = Self.familyOnDisk(disk).filter { !Self.bystanders.contains($0) }
            #expect(family.count >= 5, "\(label): \(family)")
            let others = disk.files.filter { !family.contains($0.key) }

            let removed = try Journal.remove(at: Self.path, fileSystem: disk)

            #expect(removed == family.count, "\(label)")
            #expect(disk.files == others, "\(label): only the journal's own files went; every other byte in the directory is as it was")
            #expect(try Journal.remove(at: Self.path, fileSystem: disk) == 0, "\(label): removing what is not there is not an error")
        }
        // The damaged family is the interesting one: say what it holds.
        let disk = try Self.disk()
        try Self.damaged(disk)
        let names = Self.familyOnDisk(disk).map { String($0.dropFirst(Self.path.count)) }
        #expect(names == ["", ".corrupt-1", ".lock", ".snapshot-lost", ".snapshot.corrupt-1"], "\(names)")
    }

    @Test func everyNameTheJournalEverCreatesIsOneTheRemovalKnows() throws {
        // The names come from running the journal, not from this test's idea of
        // them: each file a create ever made on the way, temporaries included.
        for build in [Self.ordinary, Self.damaged] {
            let disk = try Self.disk()
            try build(disk)
            let created: [String] = disk.operations.compactMap { if case .create(let path) = $0 { path } else { nil } }
            #expect(created.contains(Self.path + ".snapshot.tmp"), "the scenario does write through a temporary")
            let known = Set(JournalFamily.members(of: "j", in: created.map { StorePath.name(of: $0) }))
            for path in created {
                #expect(known.contains(StorePath.name(of: path)), "\(path) is made by the journal and not removed with it")
            }
        }
    }

    @Test func theLogGoesFirstAndTheLockLast() {
        let names = ["j.lock", "j.snapshot", "j.corrupt-2", "j", "j.snapshot-lost", "j.snapshot.corrupt-1", "j.snapshot.tmp", "j.corrupt-1"]
        let members = JournalFamily.members(of: "j", in: names.shuffled())
        #expect(members.first == "j" && members.last == "j.lock", "\(members)")
        #expect(members.firstIndex(of: "j.snapshot")! < members.firstIndex(of: "j.snapshot-lost")!)
        #expect(Set(members) == Set(names))
    }

    @Test func nothingThereCreatesNothing() throws {
        let disk = try Self.disk()
        try Self.plant(["/d/other"], on: disk)
        let operations = disk.operationCount
        #expect(try Journal.remove(at: Self.path, fileSystem: disk) == 0)
        #expect(disk.operationCount == operations, "not even the lock file is made to find that out")
        #expect(try Journal.remove(at: "/missing/dir/j", fileSystem: disk) == 0, "no directory is no journal")
    }

    @Test func aRemovalSaysSoOnceAndCountsTheFiles() async throws {
        let disk = try Self.disk()
        try Self.ordinary(disk)
        let events = RecordingInstrumentation()
        let removed = try await withAmbient({ $0.instrumentation = events }) {
            try Journal.remove(at: Self.path, fileSystem: disk)
        }
        let event = try #require(events.events(named: "store.journal_removed").first)
        #expect(events.events(named: "store.journal_removed").count == 1)
        #expect(event["files"].map(\.description) == "\(removed)" && event["path"].map(\.description) == Self.path)
        _ = try await withAmbient({ $0.instrumentation = events }) { try Journal.remove(at: Self.path, fileSystem: disk) }
        #expect(events.events(named: "store.journal_removed").count == 1, "nothing removed, nothing said")
    }

    // MARK: What it refuses

    @Test(.failureMode("design/15", "a journal that is open is removed"))
    func aJournalOpenInThisProcessIsBusyUntilItIsClosedOrGone() throws {
        let disk = try Self.disk()
        let journal = try Journal.open(at: Self.path, fileSystem: disk)
        try journal.append(bytes("a"))
        try journal.compact(snapshot: bytes("a"))
        let before = disk.files

        let error = #expect(throws: StoreError.self) { try Journal.remove(at: Self.path, fileSystem: disk) }
        #expect(error?.kind == .busy)
        #expect(error?.detail?.contains("open in this process") == true)
        #expect(disk.files == before, "nothing was removed")
        // The journal is unharmed.
        try journal.append(bytes("b"))

        try journal.close()
        #expect(try Journal.remove(at: Self.path, fileSystem: disk) > 0)
        #expect(Self.familyOnDisk(disk).isEmpty)
        // Closing twice, and a journal dropped without close, both let go.
        try journal.close()
        do {
            let dropped = try Journal.open(at: Self.path, fileSystem: disk)
            try dropped.append(bytes("x"))
        }
        #expect(try Journal.remove(at: Self.path, fileSystem: disk) > 0, "a journal that went away without close is not open")
    }

    @Test func twoJournalsAtOnePathAreBothOpenUntilBothAreClosed() throws {
        let disk = try Self.disk()
        let first = try Journal.open(at: Self.path, fileSystem: disk)
        let second = try Journal.open(at: Self.path, fileSystem: disk)
        try first.close()
        #expect(throws: StoreError.self) { try Journal.remove(at: Self.path, fileSystem: disk) }
        try second.close()
        #expect(try Journal.remove(at: Self.path, fileSystem: disk) == 1)
    }

    @Test func anotherFileSystemObjectOrAnotherPathIsAnotherJournal() throws {
        // Same spelling, different disk: the open journal belongs to the other one.
        let one = try Self.disk()
        let other = try Self.disk()
        let journal = try Journal.open(at: Self.path, fileSystem: one)
        try journal.append(bytes("a"))
        try Self.ordinary(other)
        #expect(try Journal.remove(at: Self.path, fileSystem: other) > 0)
        #expect(throws: StoreError.self) { try Journal.remove(at: Self.path, fileSystem: one) }
        try journal.close()
    }

    @Test(.failureMode("design/15", "a journal another process holds is removed"))
    func aJournalHeldWithTheCrossProcessLockThroughAnotherHandleIsBusy() throws {
        // Two PosixFileSystem objects over one disk stand for two processes:
        // the registry does not know the writer's, the flock does.
        let dir = try TempDirectory()
        let path = dir.file("j")
        let writer = try Journal.open(at: path, fileSystem: PosixFileSystem(), options: .init(crossProcessLock: true))
        try writer.append(bytes("a"))
        try writer.compact(snapshot: bytes("a"))
        let before = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()

        let error = #expect(throws: StoreError.self) { try Journal.remove(at: path, fileSystem: PosixFileSystem()) }
        #expect(error?.kind == .busy)
        #expect(error?.detail?.contains("another process") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == before, "nothing was removed")

        try writer.close()
        #expect(try Journal.remove(at: path, fileSystem: PosixFileSystem()) == 3)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func theLockIsHeldUntilTheLastFileIsGone() throws {
        let base = try Self.disk()
        try Self.ordinary(base)
        let opens = SendableBox<[String]>([])
        let disk = WatchedDisk(base, onRemove: { path in
            // A writer that opens while the files go meets the lock, at every removal.
            do throws(StoreError) {
                let intruder = try Journal.open(at: Self.path, fileSystem: base, options: .init(crossProcessLock: true))
                try? intruder.close()
                opens.mutate { $0.append("opened while \(path) was removed") }
            } catch {
                opens.mutate { $0.append(error.kind == .busy ? "busy" : "\(error)") }
            }
        })
        #expect(try Journal.remove(at: Self.path, fileSystem: disk) == 3)
        #expect(opens.value == ["busy", "busy", "busy"], "\(opens.value)")
        // And once it is done, the lock is free: a new journal opens at the same path.
        let fresh = try Journal.open(at: Self.path, fileSystem: base, options: .init(crossProcessLock: true))
        #expect(try fresh.replay().records.isEmpty)
        try fresh.close()
    }

    @Test func aFileSystemWithNoLocksRemovesWithoutOne() throws {
        let base = try Self.disk()
        try Self.ordinary(base)
        let disk = WatchedDisk(base, locks: false)
        #expect(try Journal.remove(at: Self.path, fileSystem: disk) == 3)
        #expect(Self.familyOnDisk(base).isEmpty)
    }

    // MARK: Failure and crash

    @Test(.failureMode("design/15", "a journal's removal is interrupted"))
    func aFailureMidwayThrowsFreesTheLockAndARerunFinishes() throws {
        let disk = try Self.disk()
        try Self.damaged(disk)
        let family = Self.familyOnDisk(disk)
        disk.inject(EIO, on: .remove, skipping: 2)

        let error = #expect(throws: StoreError.self) { try Journal.remove(at: Self.path, fileSystem: disk) }
        #expect(error?.kind == .ioFailure)
        let left = Self.familyOnDisk(disk)
        #expect(left.count == family.count - 2 && left.first != Self.path, "the log went first, and what is left is the rest: \(left)")
        // The lock is not kept by the failed call: a rerun takes it and finishes.
        let rest = try Journal.remove(at: Self.path, fileSystem: disk)
        #expect(rest == left.count)
        #expect(Self.familyOnDisk(disk).isEmpty)
    }

    @Test(.failureMode("design/15", "a journal's removal is interrupted"))
    func aCrashAtAnyPointOfARemovalLeavesAFamilyThatARerunFinishes() async throws {
        for (label, build) in [("ordinary", Self.ordinary), ("damaged", Self.damaged)] {
            let report = try await exploreCrashes(
                "Journal.remove \(label)",
                setup: { disk in
                    try disk.createDirectory("/d")
                    try build(disk)
                    try Self.plant(["/d/j.bak", "/d/j2"], on: disk)
                },
                operation: { disk in
                    try Journal.remove(at: Self.path, fileSystem: disk)
                    disk.checkpoint("returned")
                },
                check: { disk, crash in
                    if crash.reached("returned"), !Self.familyOnDisk(disk).isEmpty {
                        return "remove had returned, and \(Self.familyOnDisk(disk)) is still there"
                    }
                    // Nothing that is not the journal's was touched, at any point.
                    for bystander in ["/d/j.bak", "/d/j2"] where disk.contents(of: bystander) != bytes("keep me: " + bystander) {
                        return "\(bystander) was changed"
                    }
                    // A rerun finishes, and a journal then opens fresh.
                    _ = try Journal.remove(at: Self.path, fileSystem: disk)
                    guard Self.familyOnDisk(disk).isEmpty else { return "a rerun left \(Self.familyOnDisk(disk))" }
                    let fresh = try Journal.open(at: Self.path, fileSystem: disk)
                    defer { try? fresh.close() }
                    guard try fresh.replay().records.isEmpty, try fresh.replay().snapshot == nil else { return "a removed journal came back" }
                    return nil
                }
            )
            print(report)
            #expect(report.violations.isEmpty, "\(report.violations.prefix(3).map(\.description).joined(separator: "\n"))")
            #expect(report.crashPoints >= 5)
        }
    }
}
