#if STOIC_CRYPTO
import Foundation
import Stoic
@testable import StoicSealed
import StoicStore
import StoicTesting
import Testing

/// A simulated disk that damages what is written under one name: the bytes of
/// a sealed copy that a cipher, a disk or a bug got wrong.
final class DamagingDisk: FileSystem {
    enum Damage: Sendable {
        /// One bit of the ciphertext flipped.
        case flipBit
        /// Only the first `count` bytes reach the file.
        case keep(count: Int)
        /// Other bytes entirely (a valid sealed value of something else, say).
        case replace([UInt8])
    }

    let base: SimulatedFileSystem
    private let suffix: String
    private let damage: Damage?
    private let names = SendableBox<[Int32: String]>([:])
    /// The permission bits each file had at the moment of each write to it.
    let modesAtWrite = SendableBox<[WriteMode]>([])

    struct WriteMode: Sendable {
        let path: String
        let mode: UInt16?
    }

    init(_ base: SimulatedFileSystem, damagingFilesEndingIn suffix: String = ".sealing", with damage: Damage? = nil) {
        self.base = base
        self.suffix = suffix
        self.damage = damage
    }

    var newFileMode: UInt16 { base.newFileMode }

    func open(_ path: String, mode: OpenMode) throws(StoreError) -> OpenFile {
        let file = try base.open(path, mode: mode)
        names.mutate { $0[file.rawValue] = path }
        return file
    }

    func write(_ file: OpenFile, _ bytes: [UInt8], at offset: Int) throws(StoreError) {
        guard let name = names.value[file.rawValue] else { return try base.write(file, bytes, at: offset) }
        let mode = try base.permissions(of: name)
        modesAtWrite.mutate { $0.append(WriteMode(path: name, mode: mode)) }
        guard name.hasSuffix(suffix), let damage else { return try base.write(file, bytes, at: offset) }
        var changed = bytes
        switch damage {
        case .flipBit: changed[changed.count / 2] ^= 0x10
        case .keep(let count): changed = Array(bytes.prefix(count))
        case .replace(let other): changed = other
        }
        try base.write(file, changed, at: offset)
    }

    func read(_ file: OpenFile, at offset: Int, count: Int) throws(StoreError) -> [UInt8] { try base.read(file, at: offset, count: count) }
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
    func createDirectory(_ path: String) throws(StoreError) { try base.createDirectory(path) }
    func permissions(of path: String) throws(StoreError) -> UInt16? { try base.permissions(of: path) }
    func setPermissions(_ file: OpenFile, to permissions: UInt16) throws(StoreError) { try base.setPermissions(file, to: permissions) }
    func readLink(_ path: String) throws(StoreError) -> String? { try base.readLink(path) }
}

/// `SealedFile.adopt` proves its sealed copy before the plaintext goes.
@Suite("SealedFile adoption is verified")
struct SealedFileAdoptionTests {
    static let path = SealedFileTests.path
    static let context = SealedFileTests.context
    static let plain = bytes("VERY-SECRET-PLAINTEXT-MARKER 0123456789 0123456789")

    static func plantPlaintext(on disk: SimulatedFileSystem, mode: UInt16 = 0o644) throws {
        try SealedFileTests.plant(plain, at: path, on: disk, mode: mode)
    }

    @Test(.failureMode("design/24", "an adoption's sealed copy does not open to the plaintext"), arguments: [
        ("a bit flipped", DamagingDisk.Damage.flipBit),
        ("cut short", .keep(count: 30)),
        ("cut inside the magic", .keep(count: 2)),
        ("another sealed value", .replace([])),    // replaced below with a valid seal of other bytes
    ])
    func aCopyThatDoesNotOpenToThePlaintextReplacesNothing(label: String, damage: DamagingDisk.Damage) throws {
        let (ring, _) = try makeRing()
        var damage = damage
        if case .replace = damage {
            damage = .replace(try Sealing.seal(bytes("something else entirely"), context: Self.context, key: ring.current))
        }
        let base = try SealedFileTests.disk()
        try Self.plantPlaintext(on: base)
        try SealedFileTests.plant(bytes("OLDER-PLAINTEXT-MARKER"), at: Self.path + ".previous", on: base)
        let before = base.files
        let file = SealedFile(keyring: ring, fileSystem: DamagingDisk(base, damagingFilesEndingIn: ".sealing", with: damage))

        do throws(SealedStoreError) {
            try file.adopt(path: Self.path, context: Self.context)
            Issue.record("\(label): the adoption must not succeed")
        } catch {
            guard case .verificationFailed(let cause) = error else {
                Issue.record("\(label): \(error)")
                return
            }
            switch label {
            case "a bit flipped": #expect(cause == .tampered)
            case "cut short": #expect(cause == .torn)
            case "cut inside the magic": #expect(cause == .notSealed)
            default: #expect(cause == nil, "it opened, to other bytes")
            }
            #expect(!"\(error)".contains("SECRET"), "an error names no plaintext")
        }
        #expect(base.files == before, "\(label): the plaintext, and every copy beside it, is exactly as it was, and no staged copy is left")
        #expect(try base.readAll(Self.path) == Self.plain)
        #expect(try SealedFile(keyring: ring, fileSystem: base).adopt(path: Self.path, context: Self.context) == .adopted, "and an honest disk adopts it")
    }

    @Test func aStagedCopyIsWrittenWithTheModeOfTheFileItReplaces() throws {
        for mode: UInt16 in [0o644, 0o600, 0o640] {
            let disk = try SealedFileTests.disk()
            let (ring, _) = try makeRing()
            try Self.plantPlaintext(on: disk, mode: mode)
            #expect(try SealedFile(keyring: ring, fileSystem: disk).adopt(path: Self.path, context: Self.context) == .adopted)
            #expect(try disk.permissions(of: Self.path) == mode, "an adopted \(String(mode, radix: 8)) file stays that")
            #expect(disk.files.keys.sorted() == [Self.path])
        }
    }

    @Test func aStagedCopyIsNeverMoreOpenThanTheFileItReplaces() throws {
        // The staged file's bits are set before its first byte, so a 0o600
        // plaintext is never beside a world-readable sealed copy, even for an instant.
        let base = try SealedFileTests.disk()
        let (ring, _) = try makeRing()
        try Self.plantPlaintext(on: base, mode: 0o600)
        let disk = DamagingDisk(base)
        _ = try SealedFile(keyring: ring, fileSystem: disk).adopt(path: Self.path, context: Self.context)
        let staged = disk.modesAtWrite.value.filter { $0.path == Self.path + ".sealing" }
        #expect(!staged.isEmpty && staged.allSatisfy { $0.mode == 0o600 }, "\(staged)")
        #expect(try base.permissions(of: Self.path) == 0o600)
    }

    @Test func aLeftoverStagedCopyIsReplacedAndAFinishedAdoptionCleansIt() throws {
        let (ring, _) = try makeRing()
        let sealed = try Sealing.seal(Self.plain, context: Self.context, key: ring.current)
        for leftover in [sealed, Array(sealed.prefix(2)), Array(sealed.prefix(20)), []] {
            // Plaintext still there: the next call replaces the leftover and finishes.
            let disk = try SealedFileTests.disk()
            try Self.plantPlaintext(on: disk)
            try SealedFileTests.plant(leftover, at: Self.path + ".sealing", on: disk)
            let file = SealedFile(keyring: ring, fileSystem: disk)
            #expect(try file.adopt(path: Self.path, context: Self.context) == .adopted)
            #expect(disk.files.keys.sorted() == [Self.path])
            #expect(try file.read(Self.path, context: Self.context) == Self.plain)

            // Already sealed (the rename happened, the cleanup did not): the cleanup finishes.
            let done = try SealedFileTests.disk()
            try SealedFileTests.plant(sealed, at: Self.path, on: done)
            try SealedFileTests.plant(leftover, at: Self.path + ".sealing", on: done)
            #expect(try SealedFile(keyring: ring, fileSystem: done).adopt(path: Self.path, context: Self.context) == .alreadySealed)
            #expect(done.files.keys.sorted() == [Self.path])
        }
    }

    @Test func somethingElseWhereTheStagedCopyGoesIsNeitherReplacedNorRemoved() throws {
        let disk = try SealedFileTests.disk()
        let (ring, _) = try makeRing()
        try Self.plantPlaintext(on: disk)
        try SealedFileTests.plant(bytes("NOT-OURS: another program's notes"), at: Self.path + ".sealing", on: disk)
        let before = disk.files
        let file = SealedFile(keyring: ring, fileSystem: disk)
        do throws(SealedStoreError) {
            try file.adopt(path: Self.path, context: Self.context)
            Issue.record("adoption must not overwrite a file that is not its own")
        } catch {
            if case .store(let store) = error { #expect(store.kind == .alreadyExists) } else { Issue.record("\(error)") }
        }
        #expect(disk.files == before)
        // And finishing an adoption that had already happened leaves it alone too.
        let done = try SealedFileTests.disk()
        try SealedFileTests.plant(try Sealing.seal(Self.plain, context: Self.context, key: ring.current), at: Self.path, on: done)
        try SealedFileTests.plant(bytes("NOT-OURS: another program's notes"), at: Self.path + ".sealing", on: done)
        #expect(try SealedFile(keyring: ring, fileSystem: done).adopt(path: Self.path, context: Self.context) == .alreadySealed)
        #expect(try done.readAll(Self.path + ".sealing") == bytes("NOT-OURS: another program's notes"))
    }

    @Test func aFailureWhileStagingLeavesThePlaintextAndNoStagedCopy() throws {
        for (target, skipping) in [(SimulatedFileSystem.FaultTarget.open, 1), (.write, 0), (.fullSync, 0)] {
            let disk = try SealedFileTests.disk()
            let (ring, _) = try makeRing()
            try Self.plantPlaintext(on: disk)
            let before = disk.files
            disk.inject(ENOSPC, on: target, skipping: skipping)
            do throws(SealedStoreError) {
                try SealedFile(keyring: ring, fileSystem: disk).adopt(path: Self.path, context: Self.context)
                Issue.record("\(target): the adoption must fail")
            } catch {
                if case .store = error {} else { Issue.record("\(target): \(error)") }
            }
            #expect(disk.files == before, "\(target): plaintext untouched, no staged copy")
        }
    }

    @Test func aFailedRenameLeavesThePlaintextAndNoStagedCopy() throws {
        let disk = try SealedFileTests.disk()
        let (ring, _) = try makeRing()
        try Self.plantPlaintext(on: disk)
        let before = disk.files
        disk.inject(EIO, on: .rename)
        do throws(SealedStoreError) {
            try SealedFile(keyring: ring, fileSystem: disk).adopt(path: Self.path, context: Self.context)
            Issue.record("the rename failed, so must the adoption")
        } catch {
            if case .store(let store) = error { #expect(store.kind == .ioFailure) } else { Issue.record("\(error)") }
        }
        #expect(disk.files == before)
    }

    @Test func aDirectorySyncThatFailsAfterTheRenameIsDurabilityUnknownAndKeepsTheLeftovers() throws {
        let disk = try SealedFileTests.disk()
        let (ring, _) = try makeRing()
        try Self.plantPlaintext(on: disk)
        try SealedFileTests.plant(bytes("OLDER-PLAINTEXT-MARKER"), at: Self.path + ".previous", on: disk)
        disk.inject(EIO, on: .syncDirectory)
        let file = SealedFile(keyring: ring, fileSystem: disk)
        do throws(SealedStoreError) {
            try file.adopt(path: Self.path, context: Self.context)
            Issue.record("the sync failed")
        } catch {
            if case .store(let store) = error { #expect(store.kind == .durabilityUnknown) } else { Issue.record("\(error)") }
        }
        // The sealed file is in place; the plaintext copy stays until a call can make it durable.
        #expect(Sealing.isSealed(try disk.readAll(Self.path)))
        #expect(try disk.exists(Self.path + ".previous"))
        #expect(try file.adopt(path: Self.path, context: Self.context) == .alreadySealed)
        #expect(disk.files.keys.sorted() == [Self.path])
    }

    @Test func theRealFileSystemAdoptsWithNothingLeftBeside() throws {
        let dir = try TempDirectory()
        let path = dir.file("note")
        try Data(Self.plain).write(to: URL(filePath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path)
        let (ring, _) = try makeRing()
        let file = SealedFile(keyring: ring)
        #expect(try file.adopt(path: path, context: Self.context) == .adopted)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["note"])
        #expect(try file.read(path, context: Self.context) == Self.plain)
        #expect(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int == 0o640)
    }
}
#endif
