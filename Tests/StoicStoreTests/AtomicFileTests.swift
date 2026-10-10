import Foundation
import Stoic
@testable import StoicStore
import StoicTesting
import Testing

@Suite("AtomicFile on the real file system")
struct AtomicFileTests {
    let fs = PosixFileSystem()

    @Test func roundTripsBytes() throws {
        let dir = try TempDirectory()
        let file = AtomicFile()
        #expect(try file.read(dir.file("s")) == nil)
        try file.write(bytes("first"), to: dir.file("s"))
        #expect(try file.read(dir.file("s")) == .init(bytes: bytes("first"), source: .current))
        try file.write(bytes("second"), to: dir.file("s"))
        #expect(text(try file.read(dir.file("s"))!.bytes) == "second")
        #expect(try fs.list(directory: dir.path) == ["s"])   // no temporary left behind
    }

    @Test func roundTripsAnEmptyAndALargePayload() throws {
        let dir = try TempDirectory()
        let file = AtomicFile()
        try file.write([], to: dir.file("empty"))
        #expect(try file.read(dir.file("empty"))?.bytes == [])
        let big = (0..<1_000_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        try file.write(big, to: dir.file("big"))
        #expect(try file.read(dir.file("big"))?.bytes == big)
    }

    @Test func withoutAnEnvelopeTheFileIsExactlyTheBytes() throws {
        let dir = try TempDirectory()
        let file = AtomicFile(options: .init(envelope: false))
        try file.write(bytes("plain"), to: dir.file("s"))
        #expect(text(try fs.readAll(dir.file("s"))) == "plain")
        #expect(text(try file.read(dir.file("s"))!.bytes) == "plain")
    }

    @Test func theEnvelopeIsTwentyBytesBeforeThePayload() throws {
        let dir = try TempDirectory()
        try AtomicFile().write(bytes("abc"), to: dir.file("s"))
        let raw = try fs.readAll(dir.file("s"))
        #expect(raw.count == Envelope.headerSize + 3)
        #expect(Array(raw[0..<4]) == Envelope.magic)
        #expect(Array(raw[20...]) == bytes("abc"))
    }

    @Test(arguments: [0, 3, 5, 9, 17, 19, 20, 22])   // magic, version, length, checksum, payload
    func aFlippedByteIsDetectedAndQuarantined(offset: Int) throws {
        let dir = try TempDirectory()
        let file = AtomicFile()
        try file.write(bytes("payload!!"), to: dir.file("s"))
        try flipBit(in: dir.file("s"), at: offset)
        let error = #expect(throws: StoreError.self) { try file.read(dir.file("s")) }
        #expect(error?.kind == .corrupt)
        #expect(try fs.list(directory: dir.path) == ["s.corrupt-1"])   // moved, not deleted
        #expect(try file.read(dir.file("s")) == nil)                    // and reported once
    }

    @Test(arguments: [0, 1, 19, 20, 25])
    func aTruncatedFileIsCorrupt(length: Int) throws {
        let dir = try TempDirectory()
        let file = AtomicFile()
        try file.write(bytes("payload!!"), to: dir.file("s"))
        let handle = try fs.open(dir.file("s"), mode: .readWrite)
        try fs.truncate(handle, to: length)
        try fs.close(handle)
        #expect(throws: StoreError.self) { try file.read(dir.file("s")) }
    }

    @Test func trailingGarbageIsCorrupt() throws {
        let dir = try TempDirectory()
        let file = AtomicFile()
        try file.write(bytes("payload"), to: dir.file("s"))
        let handle = try fs.open(dir.file("s"), mode: .readWrite)
        try fs.write(handle, [0], at: 27)
        try fs.close(handle)
        #expect(throws: StoreError.self) { try file.read(dir.file("s")) }
    }

    @Test func aCorruptCurrentFileFallsBackToThePreviousGeneration() async throws {
        let dir = try TempDirectory()
        let events = RecordingInstrumentation()
        try await withAmbient({ $0.instrumentation = events }) {
            let file = AtomicFile(options: .init(keepPrevious: true))
            try file.write(bytes("v1"), to: dir.file("s"))
            try file.write(bytes("v2"), to: dir.file("s"))
            #expect(try fs.list(directory: dir.path) == ["s", "s.previous"])
            try flipBit(in: dir.file("s"), at: 21)

            let found = try file.read(dir.file("s"))
            #expect(found == .init(bytes: bytes("v1"), source: .previous))
            #expect(try fs.list(directory: dir.path) == ["s.corrupt-1", "s.previous"])
            #expect(events.names == ["store.corrupt_quarantined", "store.recovered_previous"])
            #expect(events.events(named: "store.recovered_previous")[0]["reason"].map(\.description)?.hasPrefix("corrupt") == true)
        }
    }

    @Test func aMissingCurrentFileFallsBackToThePreviousGeneration() throws {
        let dir = try TempDirectory()
        let file = AtomicFile(options: .init(keepPrevious: true))
        try file.write(bytes("v1"), to: dir.file("s"))
        try file.write(bytes("v2"), to: dir.file("s"))
        try fs.remove(dir.file("s"))
        #expect(try file.read(dir.file("s")) == .init(bytes: bytes("v1"), source: .previous))
    }

    @Test func bothGenerationsCorruptIsAnErrorAndBothAreQuarantined() throws {
        let dir = try TempDirectory()
        let file = AtomicFile(options: .init(keepPrevious: true))
        try file.write(bytes("v1"), to: dir.file("s"))
        try file.write(bytes("v2"), to: dir.file("s"))
        try flipBit(in: dir.file("s"), at: 21)
        try flipBit(in: dir.file("s.previous"), at: 21)
        #expect(throws: StoreError.self) { try file.read(dir.file("s")) }
        #expect(try fs.list(directory: dir.path) == ["s.corrupt-1", "s.previous.corrupt-1"])
        #expect(try file.read(dir.file("s")) == nil)
    }

    @Test func writingOverACorruptFileDoesNotPoisonThePreviousGeneration() throws {
        let dir = try TempDirectory()
        let file = AtomicFile(options: .init(keepPrevious: true))
        try file.write(bytes("v1"), to: dir.file("s"))
        try file.write(bytes("v2"), to: dir.file("s"))
        try flipBit(in: dir.file("s"), at: 21)
        try file.write(bytes("v3"), to: dir.file("s"))
        #expect(text(try file.read(dir.file("s"))!.bytes) == "v3")
        #expect(text(try AtomicFile().read(dir.file("s.previous"))!.bytes) == "v1")   // still the last good one
    }

    @Test func theAppsValidationCanRejectAnIntactFile() throws {
        let dir = try TempDirectory()
        let file = AtomicFile(options: .init(keepPrevious: true))
        try file.write(bytes("{good}"), to: dir.file("s"))
        try file.write(bytes("{garbage"), to: dir.file("s"))
        let found = try file.read(dir.file("s"), validate: { $0.last == UInt8(ascii: "}") })
        #expect(found == .init(bytes: bytes("{good}"), source: .previous))
        #expect(try fs.list(directory: dir.path).contains("s.corrupt-1"))
    }

    @Test func quarantineNumbersGrowAndOldOnesArePruned() throws {
        let dir = try TempDirectory()
        let file = AtomicFile(options: .init(quarantineLimit: 2))
        for _ in 0..<4 {
            try file.write(bytes("payload"), to: dir.file("s"))
            try flipBit(in: dir.file("s"), at: 22)
            #expect(throws: StoreError.self) { try file.read(dir.file("s")) }
        }
        #expect(try fs.list(directory: dir.path) == ["s.corrupt-3", "s.corrupt-4"])
    }

    @Test func aStaleTemporaryFromACrashIsRemovedAndReported() async throws {
        let dir = try TempDirectory()
        let events = RecordingInstrumentation()
        try await withAmbient({ $0.instrumentation = events }) {
            let stale = try fs.open(dir.file("s.tmp"), mode: .createExclusive)
            try fs.write(stale, bytes("half a wr"), at: 0)
            try fs.close(stale)
            try AtomicFile().write(bytes("fine"), to: dir.file("s"))
            #expect(try fs.list(directory: dir.path) == ["s"])
            #expect(events.names == ["store.temp_removed"])
        }
    }

    // MARK: Permissions

    func chmod(_ path: String, to mode: UInt16) throws {
        let file = try fs.open(path, mode: .readWrite)
        try fs.setPermissions(file, to: mode)
        try fs.close(file)
    }

    @Test(arguments: [UInt16(0o600), UInt16(0o640), UInt16(0o664), UInt16(0o400)])
    func aReplacementKeepsThePermissionsOfTheFileItReplaces(mode: UInt16) throws {
        let dir = try TempDirectory()
        let file = AtomicFile(options: .init(keepPrevious: true))
        try file.write(bytes("first"), to: dir.file("s"))
        try chmod(dir.file("s"), to: mode)
        try file.write(bytes("second"), to: dir.file("s"))
        #expect(try fs.permissions(of: dir.file("s")) == mode)
        try file.write(bytes("third"), to: dir.file("s"))
        #expect(try fs.permissions(of: dir.file("s")) == mode, "and again, now that a previous generation is demoted")
        #expect(try fs.permissions(of: dir.file("s.previous")) == mode)
    }

    @Test func aNewFileTakesTheRequestedMode() throws {
        let dir = try TempDirectory()
        // The process umask can only remove bits, so ask for something it
        // cannot be expected to strip: owner read and write.
        try AtomicFile(options: .init(newFileMode: 0o600)).write(bytes("secret"), to: dir.file("s"))
        #expect(try fs.permissions(of: dir.file("s")) == 0o600)
        try AtomicFile(options: .init(newFileMode: 0o640)).write(bytes("shared"), to: dir.file("t"))
        #expect(try fs.permissions(of: dir.file("t")) == 0o640, "the mode is set exactly, not through the umask")
    }

    @Test func theRequestedModeDoesNotOverrideAnExistingFilesMode() throws {
        let dir = try TempDirectory()
        try AtomicFile().write(bytes("first"), to: dir.file("s"))
        try chmod(dir.file("s"), to: 0o640)
        try AtomicFile(options: .init(newFileMode: 0o600)).write(bytes("second"), to: dir.file("s"))
        #expect(try fs.permissions(of: dir.file("s")) == 0o640)
    }
}

@Suite("AtomicFile failures")
struct AtomicFileFailureTests {
    func disk() throws -> SimulatedFileSystem {
        let disk = SimulatedFileSystem()
        try disk.createDirectory("/d")
        disk.settle()
        return disk
    }

    @Test(arguments: [SimulatedFileSystem.FaultTarget.write, .fullSync, .rename, .syncDirectory])
    func aFailedWriteLeavesTheOldContentsAndNoTemporary(target: SimulatedFileSystem.FaultTarget) throws {
        let disk = try disk()
        let file = AtomicFile(fileSystem: disk, options: .init(keepPrevious: true))
        try file.write(bytes("old"), to: "/d/s")
        disk.inject(28, on: target)   // ENOSPC
        let error = #expect(throws: StoreError.self) { try file.write(bytes("new"), to: "/d/s") }
        #expect(error?.kind == .diskFull)
        #expect(error?.retryDecision == .stop)
        if target != .syncDirectory {   // the rename happened; only its durability is in doubt
            #expect(try disk.list(directory: "/d").filter { $0.hasSuffix(".tmp") }.isEmpty)
            #expect(text(try file.read("/d/s")!.bytes) == "old")
        }
    }

    @Test func aFullDiskIsRefusedBeforeAnythingIsTouched() throws {
        let disk = SimulatedFileSystem(capacity: 60)
        try disk.createDirectory("/d")
        let file = AtomicFile(fileSystem: disk)
        try file.write(bytes("small"), to: "/d/s")
        let error = #expect(throws: StoreError.self) { try file.write([UInt8](repeating: 1, count: 100), to: "/d/s") }
        #expect(error?.kind == .diskFull)
        #expect(error?.operation == "preflight")
        #expect(text(try file.read("/d/s")!.bytes) == "small")
        #expect(disk.operations.count == 5)   // only the first write's operations
    }

    @Test func aRetryableFailureIsRetriedByStoicsRetry() async throws {
        let disk = try disk()
        disk.inject(4, on: .fullSync, count: 2)   // EINTR twice
        let file = AtomicFile(fileSystem: disk)
        let attempts = SendableBox(0)
        try await withTestAmbient(clock: ImmediateClock()) {
            try await retry(.immediate.attempts(5)) { _ in
                attempts.mutate { $0 += 1 }
                try file.write(bytes("data"), to: "/d/s")
            }
        }
        #expect(attempts.value == 3)
        #expect(text(try file.read("/d/s")!.bytes) == "data")
    }

    @Test func aDiskFullFailureIsNotRetried() async throws {
        let disk = try disk()
        disk.inject(28, on: .write, count: 10)
        let file = AtomicFile(fileSystem: disk)
        let attempts = SendableBox(0)
        await #expect(throws: StoreError.self) {
            try await withTestAmbient(clock: ImmediateClock()) {
                try await retry(.immediate.attempts(5)) { _ in
                    attempts.mutate { $0 += 1 }
                    try file.write(bytes("data"), to: "/d/s")
                }
            }
        }
        #expect(attempts.value == 1)
    }
}
