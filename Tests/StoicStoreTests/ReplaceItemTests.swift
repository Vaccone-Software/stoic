import Foundation
import Stoic
@testable import StoicStore
import StoicTesting
import Testing

@Suite("AtomicFile.replaceItem on the real file system")
struct ReplaceItemTests {
    let fs = PosixFileSystem()

    @Test func aFileIsReplacedAndTheOldOneIsGone() throws {
        let dir = try TempDirectory()
        try AtomicFile(options: .init(envelope: false)).write(bytes("old"), to: dir.file("a"))
        try AtomicFile(options: .init(envelope: false)).write(bytes("new"), to: dir.file("a.staged"))
        try AtomicFile().replaceItem(at: dir.file("a"), withItemAt: dir.file("a.staged"))
        #expect(text(try fs.readAll(dir.file("a"))) == "new")
        #expect(try fs.list(directory: dir.path) == ["a"])
    }

    @Test func aMissingDestinationIsJustRenamedInto() throws {
        let dir = try TempDirectory()
        try AtomicFile(options: .init(envelope: false)).write(bytes("new"), to: dir.file("a.staged"))
        try AtomicFile().replaceItem(at: dir.file("a"), withItemAt: dir.file("a.staged"))
        #expect(text(try fs.readAll(dir.file("a"))) == "new")
        #expect(try fs.list(directory: dir.path) == ["a"])
    }

    @Test func aDirectoryTreeIsReplacedWholeAndTheOldTreeIsRemoved() throws {
        let dir = try TempDirectory()
        let file = AtomicFile(options: .init(envelope: false))
        for (root, label) in [("pkg", "old"), ("pkg.staged", "new")] {
            try fs.createDirectory(dir.file(root + "/inner/deeper"))
            try file.write(bytes(label), to: dir.file(root + "/inner/deeper/x"))
            try file.write(bytes(label), to: dir.file(root + "/top"))
        }
        try file.write(bytes("only old"), to: dir.file("pkg/inner/gone"))
        try file.replaceItem(at: dir.file("pkg"), withItemAt: dir.file("pkg.staged"))
        #expect(text(try fs.readAll(dir.file("pkg/top"))) == "new")
        #expect(text(try fs.readAll(dir.file("pkg/inner/deeper/x"))) == "new")
        #expect(try fs.list(directory: dir.file("pkg/inner")) == ["deeper"])
        #expect(try fs.list(directory: dir.path) == ["pkg"])
    }

    @Test func aLinkIsReplacedAsALinkAndItsTargetIsLeftAlone() throws {
        let dir = try TempDirectory()
        let file = AtomicFile(options: .init(envelope: false))
        try file.write(bytes("target"), to: dir.file("target"))
        try FileManager.default.createSymbolicLink(atPath: dir.file("a"), withDestinationPath: dir.file("target"))
        try file.write(bytes("new"), to: dir.file("a.staged"))
        try file.replaceItem(at: dir.file("a"), withItemAt: dir.file("a.staged"))
        #expect(try fs.readLink(dir.file("a")) == nil)
        #expect(text(try fs.readAll(dir.file("a"))) == "new")
        #expect(text(try fs.readAll(dir.file("target"))) == "target")
        #expect(try fs.list(directory: dir.path) == ["a", "target"])
    }

    @Test func aMissingStagedItemIsNotFoundAndTheDestinationIsUntouched() throws {
        let dir = try TempDirectory()
        try AtomicFile(options: .init(envelope: false)).write(bytes("old"), to: dir.file("a"))
        let error = #expect(throws: StoreError.self) {
            try AtomicFile().replaceItem(at: dir.file("a"), withItemAt: dir.file("nope"))
        }
        #expect(error?.kind == .notFound)
        #expect(text(try fs.readAll(dir.file("a"))) == "old")
    }
}

@Suite("AtomicFile.replaceItem failures")
struct ReplaceItemFailureTests {
    static let path = "/d/item"
    static let staged = "/d/item.staged"

    func disk() throws -> (SimulatedFileSystem, AtomicFile) {
        let disk = SimulatedFileSystem()
        try disk.createDirectory("/d")
        let file = AtomicFile(fileSystem: disk, options: .init(envelope: false))
        try file.write(bytes("old"), to: Self.path)
        try file.write(bytes("new"), to: Self.staged)
        disk.settle()
        return (disk, file)
    }

    @Test(.failureMode("design/15", "`replaceItem`'s paths are on different volumes"), arguments: [SimulatedFileSystem.FaultTarget.exchange, .rename])
    func differentVolumesAreReportedAsSuchAndNothingChanges(target: SimulatedFileSystem.FaultTarget) throws {
        let (disk, file) = try disk()
        if target == .rename { try disk.remove(Self.path) }
        let before = disk.files
        disk.inject(EXDEV, on: target)
        let error = #expect(throws: StoreError.self) { try file.replaceItem(at: Self.path, withItemAt: Self.staged) }
        #expect(error?.kind == .invalidArgument)
        #expect(error?.errnoValue == EXDEV)
        #expect(error?.description.contains("different volumes") == true)
        #expect(disk.files == before)
    }

    @Test(.failureMode("design/15", "a step of `replaceItem` before the swap fails"))
    func aFailedStepLeavesTheDestinationAndTheStagedItemAsTheyWere() throws {
        let (disk, file) = try disk()
        disk.inject(ENOSPC, on: .exchange)
        let error = #expect(throws: StoreError.self) { try file.replaceItem(at: Self.path, withItemAt: Self.staged) }
        #expect(error?.kind == .diskFull)
        #expect(text(disk.contents(of: Self.path)!) == "old")
        #expect(text(disk.contents(of: Self.staged)!) == "new")
    }

    @Test(.failureMode("design/15", "the directory sync after `replaceItem`'s swap fails"))
    func aFailedSyncAfterTheSwapIsDurabilityUnknown() throws {
        let (disk, file) = try disk()
        disk.inject(ENOSPC, on: .syncDirectory)
        let error = #expect(throws: StoreError.self) { try file.replaceItem(at: Self.path, withItemAt: Self.staged) }
        #expect(error?.kind == .durabilityUnknown)
        // The swap happened; only its durability is in doubt. The old item
        // waits at the staged path, as after a failed removal.
        #expect(text(disk.contents(of: Self.path)!) == "new")
        #expect(text(disk.contents(of: Self.staged)!) == "old")
    }

    @Test(.failureMode("design/15", "the old item cannot be removed after the swap"))
    func aFailedRemovalAfterTheSwapIsReportedNotThrown() async throws {
        let (disk, file) = try disk()
        let events = RecordingInstrumentation()
        disk.inject(EIO, on: .remove)
        try await withAmbient({ $0.instrumentation = events }) {
            try file.replaceItem(at: Self.path, withItemAt: Self.staged)
        }
        #expect(text(disk.contents(of: Self.path)!) == "new")
        #expect(text(disk.contents(of: Self.staged)!) == "old")   // left for the caller
        #expect(events.names == ["store.replace_leftover"])
    }

    @Test(.failureMode("design/15", "the file system cannot swap"))
    func aFileSystemThatCannotSwapIsUnsupported() {
        let error = #expect(throws: StoreError.self) {
            try AtomicFile(fileSystem: CannotSwap()).replaceItem(at: "/d/a", withItemAt: "/d/b")
        }
        #expect(error?.kind == .unsupported)
    }

    @Test func replacingAnItemWithItselfIsRefused() throws {
        let (_, file) = try disk()
        let error = #expect(throws: StoreError.self) { try file.replaceItem(at: Self.path, withItemAt: Self.path) }
        #expect(error?.kind == .invalidArgument)
    }
}

/// Everything exists and nothing can be swapped.
private struct CannotSwap: FileSystem {
    func open(_ path: String, mode: OpenMode) throws(StoreError) -> OpenFile { OpenFile(rawValue: 3) }
    func read(_ file: OpenFile, at offset: Int, count: Int) throws(StoreError) -> [UInt8] { [] }
    func write(_ file: OpenFile, _ bytes: [UInt8], at offset: Int) throws(StoreError) {}
    func size(of file: OpenFile) throws(StoreError) -> Int { 0 }
    func truncate(_ file: OpenFile, to size: Int) throws(StoreError) {}
    func fullSync(_ file: OpenFile) throws(StoreError) {}
    func close(_ file: OpenFile) throws(StoreError) {}
    func syncDirectory(_ directory: String) throws(StoreError) {}
    func rename(from source: String, to destination: String) throws(StoreError) {}
    func remove(_ path: String) throws(StoreError) {}
    func list(directory: String) throws(StoreError) -> [String] { [] }
    func exists(_ path: String) throws(StoreError) -> Bool { true }
    func freeSpace(at directory: String) throws(StoreError) -> UInt64 { 0 }
    func createDirectory(_ path: String) throws(StoreError) {}
}

/// A deliberately wrong replace, so the crash check can be shown to fail.
enum BrokenReplace {
    case correct
    /// Removes the destination, then renames: a crash between leaves nothing.
    case removeThenRename
    /// Forgets to sync the directory.
    case skipDirectorySync

    func replace(at path: String, withItemAt staged: String, on disk: SimulatedFileSystem) throws {
        switch self {
        case .correct:
            try AtomicFile(fileSystem: disk).replaceItem(at: path, withItemAt: staged)
        case .removeThenRename:
            try disk.remove(path)
            try disk.rename(from: staged, to: path)
            try disk.syncDirectory(StorePath.directory(of: path))
        case .skipDirectorySync:
            try disk.exchange(path, staged)
            try disk.remove(staged)
        }
    }
}

@Suite("AtomicFile.replaceItem crash consistency")
struct ReplaceItemCrashTests {
    static let old = (0..<24).map { UInt8($0) &+ 100 }
    static let new = (0..<700).map { UInt8(truncatingIfNeeded: $0 &* 13) }
    static let path = "/d/item"
    static let staged = "/d/item.staged"

    /// What the caller does first: build the new item beside the destination and make it durable.
    static func stage(_ disk: SimulatedFileSystem) throws {
        let file = try disk.open(staged, mode: .createExclusive)
        try disk.write(file, new, at: 0)
        try disk.fullSync(file)
        try disk.close(file)
        try disk.syncDirectory("/d")
    }

    static func setup(_ disk: SimulatedFileSystem, existing: Bool) throws {
        try disk.createDirectory("/d")
        if existing {
            let file = try disk.open(path, mode: .createExclusive)
            try disk.write(file, old, at: 0)
            try disk.fullSync(file)
            try disk.close(file)
            try disk.syncDirectory("/d")
        }
    }

    static func explore(_ defect: BrokenReplace, existing: Bool) async throws -> CrashReport {
        try await exploreCrashes(
            "replaceItem \(defect) existing=\(existing)",
            setup: { try setup($0, existing: existing) },
            operation: { disk in
                try stage(disk)
                try defect.replace(at: path, withItemAt: staged, on: disk)
                disk.checkpoint("returned")
            },
            check: { disk, context in
                // The invariant is about the destination only: the staged name may hold the old item.
                let read: (SimulatedFileSystem) throws -> [UInt8]? = { try? $0.readAll(path) }
                return try atomicWriteInvariant(path: path, old: existing ? old : nil, new: new, read: read)(disk, context)
            }
        )
    }

    @Test(.failureMode("design/15", "the process dies at any instruction of `replaceItem`"), .failureMode("design/15", "`replaceItem` has returned, then power is lost"), arguments: [true, false])
    func replaceIsAtomicAndDurableAtEveryCrashPoint(existing: Bool) async throws {
        let report = try await Self.explore(.correct, existing: existing)
        print(report)
        #expect(report.violations.isEmpty, "\(report.violations.prefix(3).map(\.description).joined(separator: "\n"))")
        #expect(report.crashPoints >= 6)
        #expect(report.images > report.crashPoints)
    }

    @Test(arguments: [BrokenReplace.removeThenRename, .skipDirectorySync])
    func aDefectiveReplaceFailsTheCrashCheck(defect: BrokenReplace) async throws {
        let report = try await Self.explore(defect, existing: true)
        print(report)
        #expect(!report.violations.isEmpty, "the harness did not notice \(defect)")
    }
}
