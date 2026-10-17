#if STOIC_CRYPTO
import Foundation
import Stoic
@testable import StoicSealed
import StoicStore
import StoicTesting
import Testing

@Suite("SealedFile")
struct SealedFileTests {
    static let path = "/d/notes"
    static let context = SealContext("app.notes", "n1")
    static let old = bytes("OLD-PLAINTEXT-MARKER-0123456789")
    static let new = bytes("NEW-PLAINTEXT-MARKER-abcdefghij")

    static func disk() throws -> SimulatedFileSystem {
        let disk = SimulatedFileSystem()
        try disk.createDirectory("/d")
        return disk
    }

    static func plant(_ content: [UInt8], at path: String, on disk: SimulatedFileSystem, mode: UInt16 = 0o644) throws {
        let file = try disk.open(path, mode: .createExclusive)
        try disk.setPermissions(file, to: mode)
        try disk.write(file, content, at: 0)
        try disk.fullSync(file)
        try disk.close(file)
        try disk.syncDirectory(Paths.directory(of: path))
    }

    enum Paths {
        static func directory(of path: String) -> String {
            guard let slash = path.lastIndex(of: "/") else { return "." }
            return slash == path.startIndex ? "/" : String(path[..<slash])
        }
    }

    // MARK: Round trip

    @Test(.failureMode("design/24", "a file is written and read back"))
    func aWrittenFileReadsBackAndIsNotPlaintextOnDisk() throws {
        let disk = try Self.disk()
        let (ring, _) = try makeRing()
        let file = SealedFile(keyring: ring, fileSystem: disk)
        #expect(try file.read(Self.path, context: Self.context) == nil, "no file is nil, not an error")
        try file.write(Self.old, to: Self.path, context: Self.context)
        #expect(try file.read(Self.path, context: Self.context) == Self.old)
        try file.write(Self.new, to: Self.path, context: Self.context)
        #expect(try file.read(Self.path, context: Self.context) == Self.new)
        #expect(filesHolding(bytes("PLAINTEXT-MARKER"), on: disk).isEmpty)
        #expect(disk.files.keys.sorted() == [Self.path], "no temporary left beside it")
        #expect(Sealing.isSealed(try #require(disk.contents(of: Self.path))))
        #expect(disk.contents(of: Self.path)?.count == Self.new.count + Sealing.overhead, "no envelope on top of the seal")
    }

    @Test(.failureMode("design/24", "a file is created"))
    func aNewFileIsPrivateAndAReplacementKeepsItsMode() throws {
        let disk = try Self.disk()
        let (ring, _) = try makeRing()
        let file = SealedFile(keyring: ring, fileSystem: disk)
        try file.write(Self.old, to: Self.path, context: Self.context)
        #expect(try disk.permissions(of: Self.path) == 0o600)
        try file.write(Self.new, to: Self.path, context: Self.context)
        #expect(try disk.permissions(of: Self.path) == 0o600)
        let custom = SealedFile(keyring: ring, fileSystem: disk, options: .init(newFileMode: 0o640))
        try custom.write(Self.old, to: "/d/other", context: Self.context)
        #expect(try disk.permissions(of: "/d/other") == 0o640)
        // A replacement keeps the mode of what it replaces, as AtomicFile does.
        try Self.plant(bytes("x"), at: "/d/wide", on: disk, mode: 0o644)
        try file.write(Self.old, to: "/d/wide", context: Self.context)
        #expect(try disk.permissions(of: "/d/wide") == 0o644)
    }

    @Test func theRealFileSystemWritesA0o600FileAndLeavesNothingBeside() throws {
        let dir = try TempDirectory()
        let (ring, _) = try makeRing()
        let file = SealedFile(keyring: ring)
        try file.write(Self.old, to: dir.file("notes"), context: Self.context)
        #expect(try file.read(dir.file("notes"), context: Self.context) == Self.old)
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.file("notes"))
        #expect((attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["notes"])
    }

    // MARK: Previous generations

    @Test(.failureMode("design/24", "a previous generation is kept"))
    func aPreviousGenerationIsSealedToo() throws {
        let disk = try Self.disk()
        let (ring, _) = try makeRing()
        let file = SealedFile(keyring: ring, fileSystem: disk, options: .init(keepPrevious: true))
        try file.write(Self.old, to: Self.path, context: Self.context)
        try file.write(Self.new, to: Self.path, context: Self.context)
        #expect(disk.files.keys.sorted() == [Self.path, Self.path + ".previous"])
        #expect(filesHolding(bytes("PLAINTEXT-MARKER"), on: disk).isEmpty, "neither generation holds plaintext")
        let previous = try #require(disk.contents(of: Self.path + ".previous"))
        #expect(try Sealing.open(previous, context: Self.context, keyring: ring) == Self.old)
        #expect(try file.read(Self.path, context: Self.context) == Self.new)
    }

    @Test func theCurrentFileMissingFallsBackToThePreviousGeneration() throws {
        let disk = try Self.disk()
        let (ring, _) = try makeRing()
        let file = SealedFile(keyring: ring, fileSystem: disk, options: .init(keepPrevious: true))
        try file.write(Self.old, to: Self.path, context: Self.context)
        try file.write(Self.new, to: Self.path, context: Self.context)
        try disk.remove(Self.path)         // the instant between the demotion and the rename
        #expect(try file.read(Self.path, context: Self.context) == Self.old)
    }

    @Test func aCurrentFileThatDoesNotOpenIsReportedNotReplacedByAnOlderOne() throws {
        let disk = try Self.disk()
        let (ring, _) = try makeRing()
        let file = SealedFile(keyring: ring, fileSystem: disk, options: .init(keepPrevious: true))
        try file.write(Self.old, to: Self.path, context: Self.context)
        try file.write(Self.new, to: Self.path, context: Self.context)
        var damaged = try #require(disk.contents(of: Self.path))
        damaged[damaged.count - 1] ^= 1
        try disk.remove(Self.path)
        try Self.plant(damaged, at: Self.path, on: disk)
        let before = disk.files
        #expect(throws: SealedStoreError.self) { try file.read(Self.path, context: Self.context) }
        #expect(disk.files == before, "nothing renamed, quarantined or removed")
    }

    // MARK: Failures are told apart, and nothing is touched

    @Test(.failureMode("design/24", "a file is plaintext, altered, cut, or sealed under a key that is gone"))
    func eachFailureIsItsOwnKindAndTheFileIsLeftAsItIs() throws {
        let disk = try Self.disk()
        let (ring, custody) = try makeRing()
        let file = SealedFile(keyring: ring, fileSystem: disk)

        // Plaintext.
        try Self.plant(Self.old, at: "/d/plain", on: disk)
        // Altered.
        try file.write(Self.old, to: "/d/altered", context: Self.context)
        var altered = try #require(disk.contents(of: "/d/altered"))
        altered[40] ^= 1
        try disk.remove("/d/altered")
        try Self.plant(altered, at: "/d/altered", on: disk)
        // Cut.
        let sealed = try Sealing.seal(Self.old, context: Self.context, key: ring.current)
        try Self.plant(Array(sealed.prefix(20)), at: "/d/cut", on: disk)
        // Moved to another context: the same file, read as another object.
        try file.write(Self.old, to: "/d/moved", context: Self.context)
        // Sealed under a key the ring never held.
        try Self.plant(try Sealing.seal(Self.old, context: Self.context, key: .generate()), at: "/d/stranger", on: disk)

        let before = disk.files
        func failure(_ path: String, _ context: SealContext = Self.context) -> SealError? {
            do throws(SealedStoreError) { _ = try file.read(path, context: context) } catch {
                if case .seal(let seal) = error { return seal }
                Issue.record("\(path): \(error), not a seal error")
            }
            return nil
        }
        #expect(failure("/d/plain") == .notSealed)
        #expect(failure("/d/altered") == .tampered)
        #expect(failure("/d/cut") == .torn)
        #expect(failure("/d/moved", SealContext("app.notes", "n2")) == .tampered)
        if case .unknownKey? = failure("/d/stranger") {} else { Issue.record("a stranger's key is unknown") }

        // The key is lost with its custody: the data is intact, the key is not.
        let rebuilt = try Keyring.open(name: "other", custody: InMemoryKeyCustody(), ifMissing: .create).keyring
        let afterLoss = SealedFile(keyring: rebuilt, fileSystem: disk)
        do throws(SealedStoreError) { _ = try afterLoss.read("/d/moved", context: Self.context) } catch {
            if case .seal(.unknownKey) = error {} else { Issue.record("a lost key is unknownKey, not \(error)") }
        }
        _ = custody
        #expect(disk.files == before, "no read renamed, quarantined, or removed anything")
    }

    @Test func aDestroyedKeyringWritesNothingAndTheOldFileStays() throws {
        let disk = try Self.disk()
        let (ring, _) = try makeRing()
        let file = SealedFile(keyring: ring, fileSystem: disk)
        try file.write(Self.old, to: Self.path, context: Self.context)
        let before = disk.files
        try ring.destroy()
        do throws(SealedStoreError) { try file.write(Self.new, to: Self.path, context: Self.context) } catch {
            if case .keyring(.destroyed) = error {} else { Issue.record("\(error)") }
        }
        #expect(disk.files == before)
        do throws(SealedStoreError) { _ = try file.read(Self.path, context: Self.context) } catch {
            if case .seal(.unknownKey) = error {} else { Issue.record("\(error)") }
        }
    }

    @Test func aStorageFailureIsAStoreErrorAndTheOldContentsStay() throws {
        let disk = try Self.disk()
        let (ring, _) = try makeRing()
        let file = SealedFile(keyring: ring, fileSystem: disk)
        try file.write(Self.old, to: Self.path, context: Self.context)
        disk.inject(ENOSPC, on: .write)
        do throws(SealedStoreError) { try file.write(Self.new, to: Self.path, context: Self.context) } catch {
            if case .store(let store) = error { #expect(store.kind == .diskFull) } else { Issue.record("\(error)") }
        }
        #expect(try file.read(Self.path, context: Self.context) == Self.old)
        // A lost directory sync is durabilityUnknown, with the new contents in place.
        disk.inject(EIO, on: .syncDirectory)
        do throws(SealedStoreError) { try file.write(Self.new, to: Self.path, context: Self.context) } catch {
            if case .store(let store) = error { #expect(store.kind == .durabilityUnknown) } else { Issue.record("\(error)") }
        }
        #expect(try file.read(Self.path, context: Self.context) == Self.new)
    }

    // MARK: Crash consistency

    @Test(.failureMode("design/24", "the process dies at any instruction of a write"), arguments: [false, true])
    func aWriteIsOldOrNewNeverTornNeverPlaintext(keepPrevious: Bool) throws {
        for existing in [true, false] {
            let (ring, _) = try makeRing()
            let report = try exploreCrashes(
                "SealedFile.write keepPrevious=\(keepPrevious) existing=\(existing)",
                setup: { disk in
                    try disk.createDirectory("/d")
                    if existing {
                        try SealedFile(keyring: ring, fileSystem: disk, options: .init(keepPrevious: keepPrevious))
                            .write(Self.old, to: Self.path, context: Self.context)
                    }
                },
                operation: { disk in
                    try SealedFile(keyring: ring, fileSystem: disk, options: .init(keepPrevious: keepPrevious))
                        .write(Self.new, to: Self.path, context: Self.context)
                    disk.checkpoint("returned")
                },
                check: { disk, crash in
                    let found: [UInt8]?
                    do {
                        found = try SealedFile(keyring: ring, fileSystem: disk, options: .init(keepPrevious: keepPrevious))
                            .read(Self.path, context: Self.context)
                    } catch {
                        return "read threw \(error)"
                    }
                    let oldValue: [UInt8]? = existing ? Self.old : nil
                    if crash.reached("returned") {
                        guard found == Self.new else { return "the write had returned but read found \(String(describing: found.map(text)))" }
                    } else if found != oldValue && found != Self.new {
                        return "read found \(String(describing: found.map(text))): neither old nor new"
                    }
                    let leaked = filesHolding(bytes("PLAINTEXT-MARKER"), on: disk)
                    return leaked.isEmpty ? nil : "plaintext in \(leaked)"
                }
            )
            print(report)
            #expect(report.violations.isEmpty, "\(report.violations.prefix(3).joined(separator: "\n"))")
            #expect(report.crashPoints >= 6)
        }
    }

    // MARK: Adopting plaintext

    @Test(.failureMode("design/24", "a plaintext file is adopted"))
    func adoptingSealsInPlaceAndLeavesNoPlaintextCopy() throws {
        let disk = try Self.disk()
        let (ring, _) = try makeRing()
        // keepPrevious on: adoption must not keep the plaintext as a generation.
        let file = SealedFile(keyring: ring, fileSystem: disk, options: .init(keepPrevious: true))
        try Self.plant(Self.old, at: Self.path, on: disk)
        try Self.plant(bytes("OLDER-PLAINTEXT-MARKER generation"), at: Self.path + ".previous", on: disk)
        try Self.plant(bytes("STALE-PLAINTEXT-MARKER temporary"), at: Self.path + ".tmp", on: disk)

        #expect(throws: SealedStoreError.self) { try file.read(Self.path, context: Self.context) }   // reports notSealed first
        #expect(try file.adopt(path: Self.path, context: Self.context) == .adopted)

        #expect(try file.read(Self.path, context: Self.context) == Self.old)
        #expect(filesHolding(bytes("PLAINTEXT-MARKER"), on: disk).isEmpty, "no plaintext anywhere the store keeps files")
        #expect(disk.files.keys.sorted() == [Self.path], "not as a previous generation, not as a temporary")
        #expect(try file.adopt(path: Self.path, context: Self.context) == .alreadySealed)
        #expect(try file.adopt(path: "/d/nothing", context: Self.context) == .absent)
    }

    @Test func aSealedPreviousGenerationSurvivesAnAdoptionCall() throws {
        let disk = try Self.disk()
        let (ring, _) = try makeRing()
        let file = SealedFile(keyring: ring, fileSystem: disk, options: .init(keepPrevious: true))
        try file.write(Self.old, to: Self.path, context: Self.context)
        try file.write(Self.new, to: Self.path, context: Self.context)
        let before = disk.files
        #expect(try file.adopt(path: Self.path, context: Self.context) == .alreadySealed)
        #expect(disk.files == before)
    }

    @Test(.failureMode("design/24", "the process dies at any instruction of an adoption"))
    func anAdoptionIsPlaintextOrSealedNeverTornAndARerunLeavesNoPlaintext() throws {
        let (ring, _) = try makeRing()
        let report = try exploreCrashes(
            "SealedFile.adopt",
            setup: { disk in
                try disk.createDirectory("/d")
                try Self.plant(Self.old, at: Self.path, on: disk)
                try Self.plant(bytes("OLDER-PLAINTEXT-MARKER generation"), at: Self.path + ".previous", on: disk)
                try Self.plant(bytes("STALE-PLAINTEXT-MARKER temporary"), at: Self.path + ".tmp", on: disk)
            },
            operation: { disk in
                try SealedFile(keyring: ring, fileSystem: disk, options: .init(keepPrevious: true))
                    .adopt(path: Self.path, context: Self.context)
                disk.checkpoint("returned")
            },
            check: { disk, crash in
                let file = SealedFile(keyring: ring, fileSystem: disk, options: .init(keepPrevious: true))
                let raw = try disk.readAll(Self.path)
                if Sealing.isSealed(raw) {
                    guard try file.read(Self.path, context: Self.context) == Self.old else { return "sealed, but it does not open to the plaintext" }
                } else if raw != Self.old {
                    return "the file is neither the plaintext nor a sealed value: \(raw.count) bytes"
                }
                if crash.reached("returned") {
                    let leaked = filesHolding(bytes("PLAINTEXT-MARKER"), on: disk)
                    guard leaked.isEmpty else { return "adopt had returned, and plaintext is in \(leaked)" }
                }
                // Recovery is calling it again, and it must finish the job.
                _ = try file.adopt(path: Self.path, context: Self.context)
                guard try file.read(Self.path, context: Self.context) == Self.old else { return "after a rerun the value is not the plaintext" }
                let after = filesHolding(bytes("PLAINTEXT-MARKER"), on: disk)
                return after.isEmpty ? nil : "after a rerun, plaintext is in \(after)"
            }
        )
        print(report)
        #expect(report.violations.isEmpty, "\(report.violations.prefix(3).joined(separator: "\n"))")
    }

    @Test func adoptingThroughASymbolicLinkCleansBesideTheTarget() throws {
        let dir = try TempDirectory()
        let manager = FileManager.default
        try manager.createDirectory(atPath: dir.file("real"), withIntermediateDirectories: true)
        try manager.createDirectory(atPath: dir.file("links"), withIntermediateDirectories: true)
        try Data(Self.old).write(to: URL(filePath: dir.file("real/notes")))
        try Data(bytes("OLDER-PLAINTEXT-MARKER")).write(to: URL(filePath: dir.file("real/notes.previous")))
        try manager.createSymbolicLink(atPath: dir.file("links/notes"), withDestinationPath: dir.file("real/notes"))
        let (ring, _) = try makeRing()
        let file = SealedFile(keyring: ring)
        #expect(try file.adopt(path: dir.file("links/notes"), context: Self.context) == .adopted)
        #expect(try manager.destinationOfSymbolicLink(atPath: dir.file("links/notes")) == dir.file("real/notes"), "the link is still a link")
        #expect(try manager.contentsOfDirectory(atPath: dir.file("real")) == ["notes"], "the plaintext previous generation beside the target is gone")
        #expect(try file.read(dir.file("links/notes"), context: Self.context) == Self.old)
    }

    // MARK: Events

    @Test(.failureMode("design/24", "a key, error or event is printed, logged or reflected over"))
    func eventsCarryNoPlaintextKeyOrContextId() async throws {
        let disk = try Self.disk()
        let (ring, _) = try makeRing()
        let events = RecordingInstrumentation()
        let secretContext = SealContext("app.notes", "SECRET-OBJECT-ID")
        try await withAmbient({ $0.instrumentation = events }) {
            let file = SealedFile(keyring: ring, fileSystem: disk)
            try Self.plant(Self.old, at: "/d/legacy", on: disk)
            try file.adopt(path: "/d/legacy", context: secretContext)
            try file.write(Self.new, to: Self.path, context: secretContext)
            _ = try? file.read(Self.path, context: SealContext("app.notes", "ANOTHER-SECRET-ID"))
            _ = try? ring.rotate()
        }
        let names = events.names.map(\.rawValue)
        #expect(names.contains("sealed.file_adopted") && names.contains("sealed.open_failed") && names.contains("sealed.key_rotated"))
        let everything = events.events.map { event in
            ([event.name.rawValue, event.label ?? ""] + event.fields.map { "\($0.key)=\($0.value)" }).joined(separator: " ")
        }.joined(separator: "\n")
        for secret in ["PLAINTEXT-MARKER", "SECRET-OBJECT-ID", "ANOTHER-SECRET-ID", try ring.current.id.description, hexString(Array(Self.old.prefix(8)))] {
            #expect(!everything.contains(secret), "\(secret) is in an event:\n\(everything)")
        }
        let failed = try #require(events.events(named: "sealed.open_failed").first)
        #expect(failed["kind"].map(\.description) == "tampered")
        #expect(failed["purpose"].map(\.description) == "app.notes")
    }
}
#endif
