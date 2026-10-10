import Foundation
import Stoic
@testable import StoicStore
import Testing

@Suite("CRC-32C")
struct CRC32CTests {
    @Test func matchesTheStandardCheckValue() {
        #expect(CRC32C.checksum(bytes("123456789")) == 0xE306_9283)
        #expect(CRC32C.checksum([UInt8]()) == 0)
        #expect(CRC32C.checksum([UInt8](repeating: 0, count: 32)) == 0x8A91_36AA)
        #expect(CRC32C.checksum([UInt8](repeating: 0xFF, count: 32)) == 0x62A8_AB43)
    }

    @Test func incrementalEqualsOneShot() {
        let data = (0..<1000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        var running = CRC32C.Running()
        running.update(data[..<137])
        running.update(data[137...])
        #expect(running.value == CRC32C.checksum(data))
    }

    @Test func everySingleBitFlipChangesTheChecksum() {
        let data = bytes("the quick brown fox")
        let original = CRC32C.checksum(data)
        for index in data.indices {
            for bit in 0..<8 {
                var flipped = data
                flipped[index] ^= 1 << UInt8(bit)
                #expect(CRC32C.checksum(flipped) != original)
            }
        }
    }
}

@Suite("PosixFileSystem")
struct PosixFileSystemTests {
    let fs = PosixFileSystem()

    @Test func writesAndReadsAtOffsets() throws {
        let dir = try TempDirectory()
        let path = dir.file("a")
        let file = try fs.open(path, mode: .createExclusive)
        try fs.write(file, bytes("hello"), at: 0)
        try fs.write(file, bytes("world"), at: 5)
        try fs.write(file, bytes("!"), at: 12)   // leaves a two-byte hole
        #expect(try fs.size(of: file) == 13)
        #expect(try fs.read(file, at: 3, count: 4) == bytes("lowo"))
        #expect(try fs.read(file, at: 10, count: 10) == [0, 0, 0x21])   // short read at end
        #expect(try fs.read(file, at: 100, count: 4).isEmpty)
        try fs.truncate(file, to: 5)
        #expect(try fs.size(of: file) == 5)
        try fs.fullSync(file)
        try fs.close(file)
        #expect(text(try fs.readAll(path)) == "hello")
    }

    @Test func createExclusiveRefusesAnExistingFile() throws {
        let dir = try TempDirectory()
        let path = dir.file("a")
        try fs.close(try fs.open(path, mode: .createExclusive))
        let error = #expect(throws: StoreError.self) { try fs.open(path, mode: .createExclusive) }
        #expect(error?.kind == .alreadyExists)
    }

    @Test func readWriteCreateKeepsContents() throws {
        let dir = try TempDirectory()
        let path = dir.file("a")
        var file = try fs.open(path, mode: .readWriteCreate)
        try fs.write(file, bytes("kept"), at: 0)
        try fs.close(file)
        file = try fs.open(path, mode: .readWriteCreate)
        #expect(try fs.size(of: file) == 4)
        try fs.close(file)
    }

    @Test func missingFilesAreNotFound() throws {
        let dir = try TempDirectory()
        let error = #expect(throws: StoreError.self) { try fs.open(dir.file("nope"), mode: .read) }
        #expect(error?.kind == .notFound)
        #expect(try fs.exists(dir.file("nope")) == false)
    }

    @Test func renameReplacesAndRemoveDeletes() throws {
        let dir = try TempDirectory()
        for (name, content) in [("a", "one"), ("b", "two")] {
            let file = try fs.open(dir.file(name), mode: .createExclusive)
            try fs.write(file, bytes(content), at: 0)
            try fs.close(file)
        }
        try fs.rename(from: dir.file("a"), to: dir.file("b"))
        try fs.syncDirectory(dir.path)
        #expect(try fs.list(directory: dir.path) == ["b"])
        #expect(text(try fs.readAll(dir.file("b"))) == "one")
        try fs.remove(dir.file("b"))
        #expect(try fs.list(directory: dir.path).isEmpty)
    }

    @Test func listIsSortedAndOmitsDots() throws {
        let dir = try TempDirectory()
        for name in ["c", "a", "b"] { try fs.close(try fs.open(dir.file(name), mode: .createExclusive)) }
        #expect(try fs.list(directory: dir.path) == ["a", "b", "c"])
    }

    @Test func createDirectoryMakesParentsAndIsIdempotent() throws {
        let dir = try TempDirectory()
        let nested = dir.file("x/y/z")
        try fs.createDirectory(nested)
        try fs.createDirectory(nested)
        #expect(try fs.exists(nested))
    }

    @Test func freeSpaceIsPositive() throws {
        let dir = try TempDirectory()
        #expect(try fs.freeSpace(at: dir.path) > 0)
    }

    @Test func writesLargerThanAPageSurviveInOnePiece() throws {
        let dir = try TempDirectory()
        let big = (0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 >> 3) }
        let file = try fs.open(dir.file("big"), mode: .createExclusive)
        try fs.write(file, big, at: 0)
        try fs.fullSync(file)
        try fs.close(file)
        #expect(try fs.readAll(dir.file("big")) == big)
    }

    @Test func storeErrorsClassifyThemselvesForRetry() {
        for code in [ENOSPC, EROFS, EDQUOT, EACCES, EPERM, ENOENT, EIO] {
            #expect(StoreError(errno: code, operation: "t").retryDecision == .stop, "errno \(code)")
        }
        for code in [EINTR, EAGAIN, EBUSY, EMFILE, ENFILE, ENOMEM] {
            #expect(StoreError(errno: code, operation: "t").retryDecision == .retry, "errno \(code)")
        }
        #expect(StoreError(errno: ENOSPC, operation: "write").kind == .diskFull)
    }
}
