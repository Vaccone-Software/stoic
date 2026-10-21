import Foundation
@testable import StoicStore
import Synchronization
import Testing

@Suite("SimulatedFileSystem")
struct SimulatedFileSystemTests {
    func makeDisk() throws -> SimulatedFileSystem {
        let disk = SimulatedFileSystem()
        try disk.createDirectory("/d")
        disk.settle()
        return disk
    }

    func create(_ disk: SimulatedFileSystem, _ path: String, _ content: String, sync: Bool) throws {
        let file = try disk.open(path, mode: .createExclusive)
        try disk.write(file, bytes(content), at: 0)
        if sync { try disk.fullSync(file) }
        try disk.close(file)
    }

    @Test func behavesLikeAFileSystemUntilItCrashes() throws {
        let disk = try makeDisk()
        try create(disk, "/d/a", "hello", sync: false)
        #expect(text(try disk.readAll("/d/a")) == "hello")
        try disk.rename(from: "/d/a", to: "/d/b")
        #expect(try disk.list(directory: "/d") == ["b"])
        #expect(try disk.exists("/d/a") == false)
        let error = #expect(throws: StoreError.self) { try disk.open("/d/a", mode: .read) }
        #expect(error?.kind == .notFound)
        let file = try disk.open("/d/b", mode: .readWrite)
        try disk.write(file, bytes("XY"), at: 8)   // a hole reads as zeros
        #expect(try disk.read(file, at: 4, count: 10) == [UInt8]("o".utf8) + [0, 0, 0] + bytes("XY"))
        try disk.truncate(file, to: 2)
        #expect(try disk.size(of: file) == 2)
    }

    @Test func aCrashDiscardsWhatWasNeverSynced() throws {
        let disk = try makeDisk()
        try create(disk, "/d/a", "unsynced", sync: false)
        disk.crash()
        #expect(disk.contents(of: "/d/a") == nil)   // not even the name survived
    }

    @Test func fileSyncDoesNotMakeTheNameDurable() throws {
        let disk = try makeDisk()
        try create(disk, "/d/a", "data", sync: true)
        disk.crash()
        #expect(disk.contents(of: "/d/a") == nil)
    }

    @Test func directorySyncDoesNotMakeTheDataDurable() throws {
        let disk = try makeDisk()
        try create(disk, "/d/a", "data", sync: false)
        try disk.syncDirectory("/d")
        disk.crash()
        #expect(disk.contents(of: "/d/a") == [])   // the name, with nothing in it
    }

    @Test func bothSyncsMakeAFileDurable() throws {
        let disk = try makeDisk()
        try create(disk, "/d/a", "data", sync: true)
        try disk.syncDirectory("/d")
        disk.crash()
        #expect(disk.contents(of: "/d/a").map(text) == "data")
        #expect(!disk.hasPendingChanges)
    }

    @Test func aRenameIsPendingUntilTheDirectoryIsSynced() throws {
        let disk = try makeDisk()
        try create(disk, "/d/old", "old", sync: true)
        try disk.syncDirectory("/d")
        disk.settle()
        try create(disk, "/d/new", "new", sync: true)
        try disk.rename(from: "/d/new", to: "/d/old")
        disk.crash()
        #expect(disk.contents(of: "/d/old").map(text) == "old")
    }

    @Test func theLogRecordsEveryDurabilityRelevantCall() throws {
        let disk = try makeDisk()
        try create(disk, "/d/a", "ab", sync: true)
        disk.checkpoint("created")
        try disk.rename(from: "/d/a", to: "/d/b")
        try disk.syncDirectory("/d")
        #expect(disk.operations.map(\.description) == [
            "create /d/a", "write /d/a [0..<2]", "fullSync /d/a", "rename /d/a -> /d/b", "syncDirectory /d",
        ])
        #expect(disk.checkpoints == [.init(label: "created", operationCount: 3)])
    }

    @Test func aFailedSyncDropsThePendingWritesForGood() throws {
        let disk = try makeDisk()
        try create(disk, "/d/a", "old", sync: true)
        try disk.syncDirectory("/d")
        disk.settle()
        let file = try disk.open("/d/a", mode: .readWrite)
        try disk.write(file, bytes("new"), at: 0)
        disk.inject(EIO, on: .fullSync)
        #expect(throws: StoreError.self) { try disk.fullSync(file) }
        #expect(text(try disk.read(file, at: 0, count: 3)) == "new", "readers still see the write")
        try disk.fullSync(file)   // succeeds, and proves nothing
        try disk.close(file)
        disk.crash()
        #expect(disk.contents(of: "/d/a").map(text) == "old")
    }

    @Test func aDirectoryIsANameInItsParentUntilTheParentIsSynced() throws {
        let disk = try makeDisk()
        try disk.createDirectory("/d/sub/deeper")
        #expect(disk.operations.map(\.description) == [
            "createDirectory /d/sub", "syncDirectory /d", "createDirectory /d/sub/deeper", "syncDirectory /d/sub",
        ])
        try create(disk, "/d/sub/deeper/f", "data", sync: true)
        try disk.syncDirectory("/d/sub/deeper")
        // Durable once createDirectory returned.
        let last = disk.crashImages(afterOperation: disk.operationCount)
        #expect(last.allSatisfy { $0.fileSystem.contents(of: "/d/sub/deeper/f").map(text) == "data" })
        // A crash before the parent's sync can lose the directory, and with
        // it a file whose own name and data were synced.
        let early = disk.crashImages(afterOperation: 1)
        #expect(early.contains { (try? $0.fileSystem.exists("/d/sub")) == false })
    }

    @Test func aFileInALostDirectoryIsLostWithIt() throws {
        // A directory made by something other than createDirectory, which
        // never synced its parent.
        let disk = SimulatedFileSystem()
        disk.state.withLock { state in
            state.directories = ["/a"]
            state.pendingDirOps = [.makeDirectory(path: "/a")]
        }
        try create(disk, "/a/f", "data", sync: true)
        try disk.syncDirectory("/a")   // the file's name is durable in /a; /a itself is not in /
        disk.crash()
        #expect(disk.contents(of: "/a/f") == nil)
        #expect(try !disk.exists("/a"))
    }

    @Test func crashImagesAtTheStartAndEndAreSingletons() throws {
        let disk = try makeDisk()
        try create(disk, "/d/a", "x", sync: true)
        try disk.syncDirectory("/d")
        #expect(disk.crashImages(afterOperation: 0).count == 1)
        let last = disk.crashImages(afterOperation: disk.operationCount)
        #expect(last.count == 1)
        #expect(last[0].fileSystem.contents(of: "/d/a").map(text) == "x")
    }

    @Test func crashImagesIncludeTornWritesAtEveryByte() throws {
        let disk = try makeDisk()
        try create(disk, "/d/a", "abcd", sync: false)
        // After the write, before any sync: the name may or may not be there,
        // and the data may be cut anywhere.
        let images = disk.crashImages(afterOperation: 2)
        let seen = Set(images.compactMap { $0.fileSystem.contents(of: "/d/a").map(text) })
        #expect(seen == ["", "a", "ab", "abc", "abcd"])
        #expect(images.contains { $0.fileSystem.contents(of: "/d/a") == nil })
    }

    @Test func crashImagesIncludeReorderedWrites() throws {
        let disk = try makeDisk()
        let file = try disk.open("/d/a", mode: .createExclusive)
        try disk.fullSync(file)
        try disk.syncDirectory("/d")
        disk.settle()
        try disk.write(file, bytes("11"), at: 0)
        try disk.write(file, bytes("22"), at: 2)
        let seen = Set(disk.crashImages(afterOperation: 2).compactMap { $0.fileSystem.contents(of: "/d/a") })
        // The second write alone leaves a hole of zeros.
        #expect(seen.contains([0, 0] + bytes("22")))
        #expect(seen.contains(bytes("1122")))
        #expect(seen.contains(bytes("11")))
        #expect(seen.contains([]))
    }

    @Test func aRenameCanBecomeDurableWithoutTheCreateThatPrecededIt() throws {
        let disk = try makeDisk()
        try create(disk, "/d/tmp", "data", sync: true)
        try disk.rename(from: "/d/tmp", to: "/d/final")
        let seen = disk.crashImages(afterOperation: disk.operationCount)
        #expect(seen.contains { $0.fileSystem.contents(of: "/d/final").map(text) == "data" && $0.fileSystem.contents(of: "/d/tmp") == nil })
        #expect(seen.contains { $0.fileSystem.contents(of: "/d/final") == nil })
    }

    @Test func imagesThatLookIdenticalAreReturnedOnce() throws {
        let disk = try makeDisk()
        try create(disk, "/d/a", "abc", sync: true)
        try disk.syncDirectory("/d")
        let images = disk.crashImages(afterOperation: disk.operationCount - 1, samples: 200)
        let keys = images.map { $0.fileSystem.files }
        #expect(Set(keys.map { $0.keys.sorted() + $0.values.map(text) }).count == keys.count)
    }

    @Test func crashImagesAreReproducibleFromTheirSeed() throws {
        let disk = try makeDisk()
        try create(disk, "/d/a", "abcdefgh", sync: false)
        try create(disk, "/d/b", "12345678", sync: false)
        let first = disk.crashImages(afterOperation: disk.operationCount, seed: 9).map(\.description)
        let second = disk.crashImages(afterOperation: disk.operationCount, seed: 9).map(\.description)
        #expect(first == second)
    }

    @Test func aFullDiskRefusesWritesWithoutChangingAnything() throws {
        let disk = SimulatedFileSystem(capacity: 10)
        try disk.createDirectory("/d")
        let file = try disk.open("/d/a", mode: .createExclusive)
        try disk.write(file, bytes("12345678"), at: 0)
        #expect(try disk.freeSpace(at: "/d") == 2)
        let error = #expect(throws: StoreError.self) { try disk.write(file, bytes("abc"), at: 8) }
        #expect(error?.kind == .diskFull)
        #expect(text(try disk.readAll("/d/a")) == "12345678")
    }

    @Test func scriptedFaultsFailTheNthMatchingCall() throws {
        let disk = try makeDisk()
        disk.inject(5, on: .fullSync, skipping: 1)   // EIO on the second fullSync
        let a = try disk.open("/d/a", mode: .createExclusive)
        try disk.fullSync(a)
        let error = #expect(throws: StoreError.self) { try disk.fullSync(a) }
        #expect(error?.kind == .ioFailure)
        try disk.fullSync(a)   // the fault was used up
    }

    @Test func permissionBitsFollowTheFileThroughRenamesAndCrashes() throws {
        let disk = try makeDisk()
        let file = try disk.open("/d/a", mode: .createExclusive)
        #expect(try disk.permissions(of: "/d/a") == 0o644)
        try disk.setPermissions(file, to: 0o600)
        try disk.write(file, bytes("secret"), at: 0)
        try disk.fullSync(file)
        try disk.close(file)
        try disk.rename(from: "/d/a", to: "/d/b")
        try disk.syncDirectory("/d")
        #expect(try disk.permissions(of: "/d/a") == nil)
        #expect(try disk.permissions(of: "/d/b") == 0o600)
        for image in disk.crashImages(afterOperation: disk.operationCount) {
            #expect(try image.fileSystem.permissions(of: "/d/b") == 0o600 || image.fileSystem.contents(of: "/d/b") == nil)
        }
        disk.crash()
        #expect(try disk.permissions(of: "/d/b") == 0o600)
    }

    /// Plants `text` at `path` and makes the bytes and the name durable.
    func plant(_ disk: SimulatedFileSystem, _ path: String, _ text: String) throws {
        let file = try disk.open(path, mode: .createExclusive)
        try disk.write(file, bytes(text), at: 0)
        try disk.fullSync(file)
        try disk.close(file)
        try disk.syncDirectory(StorePath.directory(of: path))
    }

    @Test func aDirectoryExchangeIsOneOperationAndACrashKeepsOneWholeTree() throws {
        let disk = SimulatedFileSystem()
        try disk.createDirectory("/d/dest/nested")
        try disk.createDirectory("/d/staged/nested")
        try plant(disk, "/d/dest/old", "old")
        try plant(disk, "/d/dest/nested/old", "old-nested")
        try plant(disk, "/d/staged/new", "new")
        try plant(disk, "/d/staged/nested/new", "new-nested")
        disk.settle()
        try disk.exchange("/d/dest", "/d/staged")
        #expect(disk.contents(of: "/d/dest/new").map(text) == "new")
        #expect(disk.contents(of: "/d/dest/nested/new").map(text) == "new-nested")
        #expect(disk.contents(of: "/d/staged/old").map(text) == "old")
        let images = disk.crashImages(afterOperation: disk.operationCount)
        #expect(images.contains { $0.fileSystem.contents(of: "/d/dest/new") != nil && $0.fileSystem.contents(of: "/d/staged/old") != nil })
        #expect(images.contains { $0.fileSystem.contents(of: "/d/staged/new") != nil && $0.fileSystem.contents(of: "/d/dest/old") != nil })
        for image in images {
            let swapped = image.fileSystem.contents(of: "/d/dest/new") != nil
            let original = image.fileSystem.contents(of: "/d/staged/new") != nil
            #expect(swapped != original, "a crash keeps one whole tree: \(image.description)")
            if swapped {
                #expect(image.fileSystem.contents(of: "/d/dest/nested/new").map(text) == "new-nested")
                #expect(image.fileSystem.contents(of: "/d/staged/nested/old").map(text) == "old-nested")
            } else {
                #expect(image.fileSystem.contents(of: "/d/dest/nested/old").map(text) == "old-nested")
                #expect(image.fileSystem.contents(of: "/d/staged/nested/new").map(text) == "new-nested")
            }
        }
    }

    @Test func removingATreeAfterAnUnsyncedExchangeCanDropTheTreeTheSwapDidNotCommit() throws {
        let disk = SimulatedFileSystem()
        try disk.createDirectory("/d/dest")
        try disk.createDirectory("/d/staged")
        try plant(disk, "/d/dest/old", "old")
        try plant(disk, "/d/staged/new", "new")
        disk.settle()
        try disk.exchange("/d/dest", "/d/staged")
        try disk.removeTree("/d/staged")
        let images = disk.crashImages(afterOperation: disk.operationCount)
        #expect(
            images.contains {
                $0.fileSystem.contents(of: "/d/dest/new") == nil && $0.fileSystem.contents(of: "/d/staged/new") == nil
            },
            "keeping the removal and dropping the swap unlinks the new tree")
        #expect(
            images.contains { $0.fileSystem.contents(of: "/d/staged/new").map(text) == "new" },
            "dropping both leaves the new tree where the swap had not committed it")
    }
}
