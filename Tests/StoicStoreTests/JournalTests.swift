import Foundation
import Stoic
@testable import StoicStore
import StoicTesting
import Testing

@Suite("Journal")
struct JournalTests {
    let fs = PosixFileSystem()

    func payloads(_ replay: Journal.Replay) -> [String] { replay.records.map { text($0.bytes) } }

    @Test func appendsAreNumberedAndReplayedInOrder() throws {
        let dir = try TempDirectory()
        let journal = try Journal.open(at: dir.file("j"))
        #expect(try journal.append(bytes("a")) == 1)
        #expect(try journal.append(bytes("b")) == 2)
        #expect(try journal.append(batch: [bytes("c"), bytes("d"), []]) == [3, 4, 5])
        let replay = try journal.replay()
        #expect(replay.snapshot == nil)
        #expect(payloads(replay) == ["a", "b", "c", "d", ""])
        #expect(replay.records.map(\.sequence) == [1, 2, 3, 4, 5])
        #expect(journal.lastSequence == 5)
    }

    @Test func aReopenedJournalReplaysWhatWasAppendedAndContinuesTheNumbering() throws {
        let dir = try TempDirectory()
        var journal = try Journal.open(at: dir.file("j"))
        try journal.append(bytes("a"))
        try journal.append(bytes("b"))
        try journal.close()
        journal = try Journal.open(at: dir.file("j"))
        #expect(journal.openReport == .init(droppedBytes: 0, staleRecords: 0, records: 2))
        #expect(payloads(try journal.replay()) == ["a", "b"])
        #expect(try journal.append(bytes("c")) == 3)
    }

    @Test(arguments: [1, 7, 8, 15, 16, 17, 20])   // cut inside the header, the sequence, the payload
    func aTornTailIsCutAtOpenAndReported(cutAt: Int) async throws {
        let dir = try TempDirectory()
        let events = RecordingInstrumentation()
        try await withAmbient({ $0.instrumentation = events }) {
            var journal = try Journal.open(at: dir.file("j"))
            try journal.append(bytes("first"))
            let intact = journal.byteCount
            try journal.append(bytes("second-record"))
            try journal.close()

            let file = try fs.open(dir.file("j"), mode: .readWrite)
            try fs.truncate(file, to: intact + cutAt)
            try fs.close(file)

            journal = try Journal.open(at: dir.file("j"))
            #expect(journal.openReport.droppedBytes == cutAt)
            #expect(payloads(try journal.replay()) == ["first"])
            #expect(events.events(named: "store.journal_truncated").first?["droppedBytes"].map(\.description) == "\(cutAt)")

            // The tail is gone from the file, so the next record is not hidden behind garbage.
            try journal.append(bytes("third"))
            try journal.close()
            journal = try Journal.open(at: dir.file("j"))
            #expect(payloads(try journal.replay()) == ["first", "third"])
            #expect(journal.openReport.droppedBytes == 0)
        }
    }

    @Test func aFlippedByteInTheMiddleEndsTheLogThere() async throws {
        let dir = try TempDirectory()
        var journal = try Journal.open(at: dir.file("j"))
        try journal.append(bytes("one"))
        let first = journal.byteCount
        try journal.append(bytes("two"))
        try journal.append(bytes("three"))
        try journal.close()
        try flipBit(in: dir.file("j"), at: first + 17)   // inside "two"'s payload
        journal = try Journal.open(at: dir.file("j"))
        #expect(payloads(try journal.replay()) == ["one"])
        #expect(journal.openReport.droppedBytes > 0)
    }

    @Test func aHoleOfZerosIsNeverARecord() throws {
        let dir = try TempDirectory()
        var journal = try Journal.open(at: dir.file("j"))
        try journal.append(bytes("one"))
        try journal.close()
        let file = try fs.open(dir.file("j"), mode: .readWrite)
        try fs.write(file, [UInt8](repeating: 0, count: 64), at: try fs.size(of: file))
        try fs.close(file)
        journal = try Journal.open(at: dir.file("j"))
        #expect(payloads(try journal.replay()) == ["one"])
        #expect(journal.openReport.droppedBytes == 64)
    }

    @Test func aRecordLargerThanTheLimitIsRefused() throws {
        let dir = try TempDirectory()
        let journal = try Journal.open(at: dir.file("j"), options: .init(maxRecordSize: 8))
        let error = #expect(throws: StoreError.self) { try journal.append([UInt8](repeating: 0, count: 9)) }
        #expect(error?.kind == .invalidArgument)
        try journal.append([UInt8](repeating: 0, count: 8))
    }

    @Test func aLengthFieldClaimingAHugeRecordIsNotTrusted() {
        var wild = Journal.frame(bytes("x"), sequence: 1)
        wild.replaceSubrange(0..<4, with: [0xFF, 0xFF, 0xFF, 0x7F])
        #expect(Journal.scan(wild, maxRecordSize: 1 << 20).records.isEmpty)
    }

    @Test func compactionFoldsTheLogIntoASnapshotAndNumberingContinues() throws {
        let dir = try TempDirectory()
        var journal = try Journal.open(at: dir.file("j"))
        for name in ["a", "b", "c"] { try journal.append(bytes(name)) }
        try journal.compact { replay in bytes(payloads(replay).joined(separator: "|")) }
        #expect(journal.byteCount == 0)
        #expect(try journal.append(bytes("d")) == 4)
        var replay = try journal.replay()
        #expect(replay.snapshot.map { text($0.bytes) } == "a|b|c")
        #expect(replay.snapshot?.through == 3)
        #expect(payloads(replay) == ["d"])

        try journal.compact { replay in bytes(text(replay.snapshot!.bytes) + "|" + payloads(replay).joined(separator: "|")) }
        try journal.close()
        journal = try Journal.open(at: dir.file("j"))
        replay = try journal.replay()
        #expect(replay.snapshot.map { text($0.bytes) } == "a|b|c|d")
        #expect(replay.records.isEmpty)
        #expect(try journal.append(bytes("e")) == 5)
    }

    @Test func aCompactionInterruptedBeforeTheTruncationIsFinishedAtOpen() throws {
        let dir = try TempDirectory()
        var journal = try Journal.open(at: dir.file("j"))
        try journal.append(bytes("a"))
        try journal.append(bytes("b"))
        try journal.close()
        // The snapshot reached the disk; the truncation did not.
        try AtomicFile().write(littleEndian(UInt64(2)) + bytes("a|b"), to: dir.file("j.snapshot"))
        journal = try Journal.open(at: dir.file("j"))
        #expect(journal.openReport == .init(droppedBytes: 0, staleRecords: 2, records: 0))
        #expect(journal.byteCount == 0)
        let replay = try journal.replay()
        #expect(replay.snapshot.map { text($0.bytes) } == "a|b")
        #expect(replay.records.isEmpty)
        #expect(try journal.append(bytes("c")) == 3)
    }

    @Test func aCorruptSnapshotIsQuarantinedAndOpenRefuses() throws {
        let dir = try TempDirectory()
        var journal = try Journal.open(at: dir.file("j"))
        try journal.append(bytes("a"))
        try journal.compact(snapshot: bytes("a"))
        try journal.close()
        try flipBit(in: dir.file("j.snapshot"), at: 25)
        let error = #expect(throws: StoreError.self) { try Journal.open(at: dir.file("j")) }
        #expect(error?.kind == .corrupt)
        #expect(try fs.list(directory: dir.path).contains("j.snapshot.corrupt-1"))
        journal = try Journal.open(at: dir.file("j"))   // the damage is reported once; then it is gone
        #expect(journal.lastSequence == 0)
    }

    @Test func manyThreadsAppendWithoutInterleavingOrGaps() async throws {
        let dir = try TempDirectory()
        let journal = try Journal.open(at: dir.file("j"))
        await withTaskGroup(of: Void.self) { group in
            for task in 0..<8 {
                group.addTask {
                    for index in 0..<25 { _ = try? journal.append(bytes("\(task):\(index)")) }
                }
            }
        }
        let replay = try journal.replay()
        #expect(replay.records.map(\.sequence) == Array(1...200))
        for task in 0..<8 {   // each task's own records stay in its order
            let mine = payloads(replay).filter { $0.hasPrefix("\(task):") }
            #expect(mine == (0..<25).map { "\(task):\($0)" })
        }
    }
}

@Suite("Journal failures")
struct JournalFailureTests {
    func disk() throws -> SimulatedFileSystem {
        let disk = SimulatedFileSystem()
        try disk.createDirectory("/d")
        return disk
    }

    @Test func aFailedWriteIsRolledBackAndTheJournalKeepsWorking() throws {
        let disk = try disk()
        let journal = try Journal.open(at: "/d/j", fileSystem: disk)
        try journal.append(bytes("a"))
        disk.inject(28, on: .write)   // ENOSPC
        let error = #expect(throws: StoreError.self) { try journal.append(bytes("b")) }
        #expect(error?.kind == .diskFull)
        try journal.append(bytes("c"))
        #expect(try journal.replay().records.map { text($0.bytes) } == ["a", "c"])
        #expect(try journal.replay().records.map(\.sequence) == [1, 2])
    }

    @Test func aFailedFullSyncPoisonsTheJournalUntilItIsReopened() throws {
        let disk = try disk()
        var journal = try Journal.open(at: "/d/j", fileSystem: disk)
        try journal.append(bytes("a"))
        disk.inject(5, on: .fullSync)   // EIO
        let error = #expect(throws: StoreError.self) { try journal.append(bytes("b")) }
        #expect(error?.kind == .ioFailure)
        let poisoned = #expect(throws: StoreError.self) { try journal.append(bytes("c")) }
        #expect(poisoned?.kind == .poisoned)
        #expect(throws: StoreError.self) { try journal.replay() }
        try journal.close()
        journal = try Journal.open(at: "/d/j", fileSystem: disk)   // settles what is really there
        #expect(try journal.replay().records.map { text($0.bytes) }.first == "a")
        try journal.append(bytes("d"))
    }

    @Test func aFailureWhileTruncatingTheLogAfterTheSnapshotLeavesAConsistentState() throws {
        let disk = try disk()
        var journal = try Journal.open(at: "/d/j", fileSystem: disk)
        try journal.append(bytes("a"))
        disk.inject(5, on: .truncate)
        #expect(throws: StoreError.self) { try journal.compact(snapshot: bytes("a")) }
        try journal.close()
        journal = try Journal.open(at: "/d/j", fileSystem: disk)
        let replay = try journal.replay()
        #expect(replay.snapshot.map { text($0.bytes) } == "a")
        #expect(replay.records.isEmpty)
    }
}
