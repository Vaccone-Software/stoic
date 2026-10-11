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

    // MARK: Damage in the middle of the log

    /// A journal of `count` records, "record-0" and on, closed; and where each starts.
    func makeJournal(_ path: String, count: Int) throws -> [Int] {
        let journal = try Journal.open(at: path)
        var starts: [Int] = []
        var end = 0
        for index in 0..<count {
            starts.append(end)
            end += Journal.headerSize + "record-\(index)".utf8.count
        }
        try journal.append(batch: (0..<count).map { bytes("record-\($0)") })   // one sync, not a hundred
        try journal.close()
        return starts
    }

    func names(except lost: Set<Int> = [], count: Int = 100) -> [String] {
        (0..<count).filter { !lost.contains($0) }.map { "record-\($0)" }
    }

    @Test func aFlippedBitInTheMiddleLosesOnlyThatRecordAndSaysSo() async throws {
        let dir = try TempDirectory()
        let events = RecordingInstrumentation()
        try await withAmbient({ $0.instrumentation = events }) {
            let starts = try makeJournal(dir.file("j"), count: 100)
            let size = try fs.readAll(dir.file("j")).count
            try flipBit(in: dir.file("j"), at: starts[50] + 17)   // inside record 50's payload

            let journal = try Journal.open(at: dir.file("j"))
            let replay = try journal.replay()
            #expect(payloads(replay) == names(except: [50]), "the other 99 survive, in order")
            #expect(replay.records.map(\.sequence) == (1...100).filter { $0 != 51 }.map(UInt64.init))
            #expect(journal.openReport.droppedBytes == 0, "nothing was cut from the end")
            #expect(journal.openReport.corruptRecords == 1)
            #expect(journal.openReport.corruption == [
                .init(offset: starts[50], length: starts[51] - starts[50], lostRecords: 1, firstLostSequence: 51),
            ])
            let event = try #require(events.events(named: "store.journal_corruption").first)
            #expect(event["offset"].map(\.description) == "\(starts[50])")
            #expect(event["lostRecords"].map(\.description) == "1")
            #expect(event["firstLostSequence"].map(\.description) == "51")
            #expect(try fs.readAll(dir.file("j")).count == size, "the damaged bytes are left where they are")
            try journal.close()
        }
    }

    @Test(arguments: Array(0..<25))   // every byte of a 25-byte record: length, checksum, sequence, payload
    func damageToAnyByteOfARecordCostsThatRecordAlone(byte: Int) throws {
        let dir = try TempDirectory()
        let starts = try makeJournal(dir.file("j"), count: 100)
        try flipBit(in: dir.file("j"), at: starts[50] + byte)
        let journal = try Journal.open(at: dir.file("j"))
        #expect(payloads(try journal.replay()) == names(except: [50]))
        #expect(journal.openReport.corruptRecords == 1)
        #expect(journal.openReport.droppedBytes == 0)
    }

    @Test func adjacentDamagedRecordsAreCountedTogether() throws {
        let dir = try TempDirectory()
        let starts = try makeJournal(dir.file("j"), count: 20)
        try flipBit(in: dir.file("j"), at: starts[7] + 20)
        try flipBit(in: dir.file("j"), at: starts[8] + 20)
        try flipBit(in: dir.file("j"), at: starts[9] + 20)
        let journal = try Journal.open(at: dir.file("j"))
        #expect(payloads(try journal.replay()) == names(except: [7, 8, 9], count: 20))
        #expect(journal.openReport.corruption == [
            .init(offset: starts[7], length: starts[10] - starts[7], lostRecords: 3, firstLostSequence: 8),
        ])
    }

    @Test func twoSeparateStretchesAreReportedSeparately() throws {
        let dir = try TempDirectory()
        let starts = try makeJournal(dir.file("j"), count: 20)
        try flipBit(in: dir.file("j"), at: starts[3] + 20)
        try flipBit(in: dir.file("j"), at: starts[12] + 20)
        let journal = try Journal.open(at: dir.file("j"))
        #expect(payloads(try journal.replay()) == names(except: [3, 12], count: 20))
        #expect(journal.openReport.corruption.map(\.offset) == [starts[3], starts[12]])
        #expect(journal.openReport.corruptRecords == 2)
    }

    @Test func theFirstRecordMayBeTheDamagedOne() throws {
        let dir = try TempDirectory()
        _ = try makeJournal(dir.file("j"), count: 10)
        try flipBit(in: dir.file("j"), at: 18)
        let journal = try Journal.open(at: dir.file("j"))
        #expect(payloads(try journal.replay()) == names(except: [0], count: 10))
        #expect(journal.openReport.corruption.first?.firstLostSequence == 1)
    }

    @Test func damageAfterASnapshotIsCountedFromTheSnapshotsSequence() throws {
        let dir = try TempDirectory()
        var journal = try Journal.open(at: dir.file("j"))
        for name in ["a", "b", "c"] { try journal.append(bytes(name)) }
        try journal.compact(snapshot: bytes("abc"))
        var starts: [Int] = []
        for index in 0..<5 {
            starts.append(journal.byteCount)
            try journal.append(bytes("post-\(index)"))
        }
        try journal.close()
        try flipBit(in: dir.file("j"), at: starts[0] + 18)   // the first record after the snapshot
        journal = try Journal.open(at: dir.file("j"))
        #expect(payloads(try journal.replay()) == ["post-1", "post-2", "post-3", "post-4"])
        #expect(journal.openReport.corruption.first?.firstLostSequence == 4)
        #expect(journal.openReport.corruptRecords == 1)
    }

    @Test func aFlippedBitInTheLastRecordIsATornTailAndIsCutAsBefore() throws {
        let dir = try TempDirectory()
        let starts = try makeJournal(dir.file("j"), count: 100)
        let size = try fs.readAll(dir.file("j")).count
        try flipBit(in: dir.file("j"), at: starts[99] + 17)
        let journal = try Journal.open(at: dir.file("j"))
        #expect(payloads(try journal.replay()) == names(except: [99]))
        #expect(journal.openReport.droppedBytes == size - starts[99])
        #expect(journal.openReport.corruption.isEmpty, "nothing intact follows it: indistinguishable from a crash")
        #expect(journal.byteCount == starts[99])
    }

    @Test func damageInTheMiddleAndATornTailAreEachHandled() throws {
        let dir = try TempDirectory()
        let starts = try makeJournal(dir.file("j"), count: 10)
        try flipBit(in: dir.file("j"), at: starts[4] + 20)
        let file = try fs.open(dir.file("j"), mode: .readWrite)
        try fs.truncate(file, to: starts[9] + 11)   // record 9 torn
        try fs.close(file)
        let journal = try Journal.open(at: dir.file("j"))
        #expect(payloads(try journal.replay()) == names(except: [4, 9], count: 10))
        #expect(journal.openReport.droppedBytes == 11)
        #expect(journal.openReport.corruptRecords == 1)
        #expect(journal.byteCount == starts[9])
    }

    @Test func theJournalKeepsWorkingAfterSkippingDamage() throws {
        let dir = try TempDirectory()
        let starts = try makeJournal(dir.file("j"), count: 10)
        try flipBit(in: dir.file("j"), at: starts[4] + 20)
        var journal = try Journal.open(at: dir.file("j"))
        #expect(try journal.append(bytes("new")) == 11, "numbering continues past every record there ever was")
        try journal.close()
        journal = try Journal.open(at: dir.file("j"))
        #expect(payloads(try journal.replay()) == names(except: [4], count: 10) + ["new"])
        #expect(journal.openReport.corruptRecords == 1, "the damage is still in the file, and is reported again")
    }

    @Test func refusingToOpenLeavesTheFileUntouched() throws {
        let dir = try TempDirectory()
        let starts = try makeJournal(dir.file("j"), count: 10)
        try flipBit(in: dir.file("j"), at: starts[4] + 20)
        let file = try fs.open(dir.file("j"), mode: .readWrite)
        try fs.write(file, [1, 2, 3], at: try fs.size(of: file))   // and a torn tail besides
        try fs.close(file)
        let before = try fs.readAll(dir.file("j"))
        let error = #expect(throws: StoreError.self) {
            try Journal.open(at: dir.file("j"), options: .init(middleDamage: .refuse))
        }
        #expect(error?.kind == .corrupt)
        #expect(try fs.readAll(dir.file("j")) == before, "not even the torn tail was cut")
        #expect(try fs.list(directory: dir.path) == ["j"])
    }

    @Test func compactingKeepsACopyOfTheDamagedLogBeforeItIsTruncated() throws {
        let dir = try TempDirectory()
        let starts = try makeJournal(dir.file("j"), count: 10)
        try flipBit(in: dir.file("j"), at: starts[4] + 20)
        let damaged = try fs.readAll(dir.file("j"))
        var journal = try Journal.open(at: dir.file("j"))
        try journal.compact { replay in bytes(payloads(replay).joined(separator: "|")) }
        #expect(try fs.readAll(dir.file("j.corrupt-1")) == damaged, "the evidence is saved before the log is cut")
        #expect(journal.byteCount == 0)
        try journal.close()
        journal = try Journal.open(at: dir.file("j"))
        #expect(journal.openReport.corruption.isEmpty)
        #expect(try journal.replay().snapshot.map { text($0.bytes) } == names(except: [4], count: 10).joined(separator: "|"))
    }

    @Test func aCompactionOfAnUndamagedLogSavesNothing() throws {
        let dir = try TempDirectory()
        _ = try makeJournal(dir.file("j"), count: 3)
        let journal = try Journal.open(at: dir.file("j"))
        try journal.compact(snapshot: bytes("x"))
        #expect(try fs.list(directory: dir.path).filter { $0.contains("corrupt") }.isEmpty)
    }

    @Test func damageThatAppearsAfterOpenIsAnErrorNotASilentSkip() throws {
        let dir = try TempDirectory()
        let starts = try makeJournal(dir.file("j"), count: 10)
        let journal = try Journal.open(at: dir.file("j"))
        try flipBit(in: dir.file("j"), at: starts[4] + 20)
        let error = #expect(throws: StoreError.self) { try journal.replay() }
        #expect(error?.kind == .corrupt)
    }

    @Test func aFrameInsideADamagedPayloadIsNotMistakenForARecord() throws {
        // A record whose payload is itself a framed record, with a sequence
        // number far above what could fit in the damaged stretch.
        let dir = try TempDirectory()
        var journal = try Journal.open(at: dir.file("j"))
        try journal.append(bytes("one"))
        let start = journal.byteCount
        try journal.append(Journal.frame(bytes("inner"), sequence: 1000))
        try journal.append(bytes("three"))
        try journal.close()
        try flipBit(in: dir.file("j"), at: start + 5)   // the outer record's checksum
        journal = try Journal.open(at: dir.file("j"))
        #expect(payloads(try journal.replay()) == ["one", "three"])
        #expect(journal.openReport.corruptRecords == 1)
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
