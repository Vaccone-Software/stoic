#if STOIC_CRYPTO
import Foundation
import Stoic
@testable import StoicSealed
import StoicStore
import StoicTesting
import Synchronization
import Testing

/// A simulated disk that says which kind of sync was asked of it.
final class SyncCountingFileSystem: FileSystem {
    let base: SimulatedFileSystem
    private let counts = Mutex((full: 0, plain: 0, directory: 0))
    init(_ base: SimulatedFileSystem) { self.base = base }
    var full: Int { counts.withLock { $0.full } }
    var plain: Int { counts.withLock { $0.plain } }
    var directory: Int { counts.withLock { $0.directory } }

    func fullSync(_ file: OpenFile) throws(StoreError) {
        counts.withLock { $0.full += 1 }
        try base.fullSync(file)
    }
    func sync(_ file: OpenFile) throws(StoreError) {
        counts.withLock { $0.plain += 1 }
        try base.fullSync(file)
    }
    func syncDirectory(_ directory: String) throws(StoreError) {
        counts.withLock { $0.directory += 1 }
        try base.syncDirectory(directory)
    }
    var newFileMode: UInt16 { base.newFileMode }
    func open(_ path: String, mode: OpenMode) throws(StoreError) -> OpenFile { try base.open(path, mode: mode) }
    func read(_ file: OpenFile, at offset: Int, count: Int) throws(StoreError) -> [UInt8] { try base.read(file, at: offset, count: count) }
    func write(_ file: OpenFile, _ bytes: [UInt8], at offset: Int) throws(StoreError) { try base.write(file, bytes, at: offset) }
    func size(of file: OpenFile) throws(StoreError) -> Int { try base.size(of: file) }
    func truncate(_ file: OpenFile, to size: Int) throws(StoreError) { try base.truncate(file, to: size) }
    func close(_ file: OpenFile) throws(StoreError) { try base.close(file) }
    func rename(from source: String, to destination: String) throws(StoreError) { try base.rename(from: source, to: destination) }
    func remove(_ path: String) throws(StoreError) { try base.remove(path) }
    func list(directory: String) throws(StoreError) -> [String] { try base.list(directory: directory) }
    func exists(_ path: String) throws(StoreError) -> Bool { try base.exists(path) }
    func freeSpace(at directory: String) throws(StoreError) -> UInt64 { try base.freeSpace(at: directory) }
    func createDirectory(_ path: String) throws(StoreError) { try base.createDirectory(path) }
    func permissions(of path: String) throws(StoreError) -> UInt16? { try base.permissions(of: path) }
    func setPermissions(_ file: OpenFile, to permissions: UInt16) throws(StoreError) { try base.setPermissions(file, to: permissions) }
}

@Suite("SealedObjectFile")
struct SealedObjectFileTests {
    static let path = "/d/clip-1"
    static let context = SealContext("app.clip", "c1")
    static let payload = bytes("CLIP-PLAINTEXT-MARKER-0123456789")

    static func disk() throws -> SimulatedFileSystem {
        let disk = SimulatedFileSystem()
        try disk.createDirectory("/d")
        return disk
    }

    @Test(.failureMode("design/24", "a file is sealed under a key of the caller's own"))
    func aFileSealedUnderAGivenKeyReadsBackOnlyUnderThatKeyAndIsNotPlaintextOnDisk() throws {
        let disk = try Self.disk()
        let file = SealedObjectFile(fileSystem: disk)
        let key = SealingKey.generate()
        #expect(try file.read(Self.path, context: Self.context, key: key) == nil)
        try file.write(Self.payload, to: Self.path, context: Self.context, key: key)
        #expect(try file.read(Self.path, context: Self.context, key: key) == Self.payload)
        #expect(filesHolding(bytes("PLAINTEXT-MARKER"), on: disk).isEmpty)
        #expect(disk.files.keys.sorted() == [Self.path])
        #expect(disk.contents(of: Self.path)?.count == Self.payload.count + Sealing.overhead, "no envelope on top of the seal")
        #expect(try disk.permissions(of: Self.path) == 0o600)

        do {
            _ = try file.read(Self.path, context: Self.context, key: SealingKey.generate())
            Issue.record("another key must not open it")
        } catch {
            guard case .seal(.unknownKey) = error else { Issue.record("expected unknownKey, got \(error)"); return }
        }
    }

    @Test func aWrongContextAndATamperedFileAreToldApartAndLeftAlone() throws {
        let disk = try Self.disk()
        let file = SealedObjectFile(fileSystem: disk)
        let key = SealingKey.generate()
        try file.write(Self.payload, to: Self.path, context: Self.context, key: key)
        do {
            _ = try file.read(Self.path, context: SealContext("app.clip", "other"), key: key)
            Issue.record("another object's context must not open it")
        } catch {
            guard case .seal(.tampered) = error else { Issue.record("expected tampered, got \(error)"); return }
        }
        let before = try #require(disk.contents(of: Self.path))
        let handle = try disk.open(Self.path, mode: .readWrite)
        try disk.write(handle, [before[40] ^ 1], at: 40)
        try disk.close(handle)
        do {
            _ = try file.read(Self.path, context: Self.context, key: key)
            Issue.record("a flipped bit must not open")
        } catch {
            guard case .seal(.tampered) = error else { Issue.record("expected tampered, got \(error)"); return }
        }
        #expect(disk.contents(of: Self.path)?.count == before.count, "not quarantined or removed")
    }

    @Test(.failureMode("design/24", "a sealed file is written with standard durability"))
    func standardDurabilityPaysNeitherAFullSyncNorADirectorySync() throws {
        let counting = SyncCountingFileSystem(try Self.disk())
        let key = SealingKey.generate()

        let standard = SealedObjectFile(fileSystem: counting, options: .init(durability: .standard))
        try standard.write(Self.payload, to: Self.path, context: Self.context, key: key)
        #expect((counting.full, counting.plain, counting.directory) == (0, 1, 0), "one plain fsync, and a rename")
        #expect(try standard.read(Self.path, context: Self.context, key: key) == Self.payload)

        let full = SealedObjectFile(fileSystem: counting)
        try full.write(Self.payload, to: "/d/clip-2", context: Self.context, key: key)
        #expect((counting.full, counting.plain, counting.directory) == (1, 1, 1), "the default is the full sync and the directory's")

        // The keyring's `SealedFile` takes the same option.
        let ring = try makeRing().ring
        let notes = SealedFile(keyring: ring, fileSystem: counting, options: .init(durability: .standard))
        try notes.write(Self.payload, to: "/d/notes", context: Self.context)
        #expect((counting.full, counting.plain, counting.directory) == (1, 2, 1))
        #expect(try notes.read("/d/notes", context: Self.context) == Self.payload)
    }

    @Test func aFailedStandardWriteLeavesTheOldValue() throws {
        let disk = try Self.disk()
        let file = SealedObjectFile(fileSystem: disk, options: .init(durability: .standard))
        let key = SealingKey.generate()
        try file.write(Self.payload, to: Self.path, context: Self.context, key: key)
        disk.inject(EIO, on: .fullSync)   // the simulation's plain sync is its one kind of sync
        #expect(throws: SealedStoreError.self) {
            try file.write(bytes("REPLACEMENT"), to: Self.path, context: Self.context, key: key)
        }
        #expect(try file.read(Self.path, context: Self.context, key: key) == Self.payload)
        #expect(disk.files.keys.sorted() == [Self.path], "no temporary left")
    }
}
#endif
