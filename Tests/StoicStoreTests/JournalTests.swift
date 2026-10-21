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

    @Test(.failureMode("design/15", "a crash tears the last record or leaves a hole"), arguments: [1, 7, 8, 15, 16, 17, 20])   // cut inside the header, the sequence, the payload
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
    /// A log of `count` records appended one at a time, laid down with one
    /// write and one sync rather than a hundred. (Not one `append(batch:)`: a
    /// batch's records stand or fall together when the damage is in the last
    /// batch, which is a different test.)
    func makeJournal(_ path: String, count: Int) throws -> [Int] {
        var starts: [Int] = []
        var log: [UInt8] = []
        for index in 0..<count {
            starts.append(log.count)
            log += Journal.frame(bytes("record-\(index)"), sequence: UInt64(index + 1))
        }
        let file = try fs.open(path, mode: .createExclusive)
        try fs.write(file, log, at: 0)
        try fs.fullSync(file)
        try fs.close(file)
        return starts
    }

    func names(except lost: Set<Int> = [], count: Int = 100) -> [String] {
        (0..<count).filter { !lost.contains($0) }.map { "record-\($0)" }
    }

    @Test(.failureMode("design/15", "a byte flips in the middle of the log")) func aFlippedBitInTheMiddleLosesOnlyThatRecordAndSaysSo() async throws {
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

    @Test(.failureMode("design/15", "a byte flips in the *last* record")) func aFlippedBitInTheLastRecordIsATornTailAndIsCutAsBefore() throws {
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

    @Test(.failureMode("design/15", "a byte flips in the *last* record")) func aFlippedBitAnywhereInTheLastBatchCutsTheWholeBatch() throws {
        let disk = SimulatedFileSystem()
        try disk.createDirectory("/d")
        let journal = try Journal.open(at: "/d/j", fileSystem: disk)
        try journal.append(bytes("alone"))
        let end = journal.byteCount
        try journal.append(batch: [bytes("one"), bytes("two"), bytes("three")])
        try journal.close()
        // The middle record of the batch: a crash that lost its page looks the same.
        try flipBit(in: "/d/j", at: end + Journal.headerSize + 3 + 12, using: disk)
        let reopened = try Journal.open(at: "/d/j", fileSystem: disk)
        #expect(payloads(try reopened.replay()) == ["alone"])
        #expect(reopened.openReport.corruption.isEmpty)
        #expect(reopened.byteCount == end)
    }

    /// A crash during a batch that kept a later page of it and not an earlier
    /// one: the batch is dropped whole, not replayed with a gap and reported
    /// as damage in the middle.
    @Test(.failureMode("design/15", "a crash keeps some pages of a batch and not others"))
    func aBatchWhoseFirstPageWasLostIsATornTail() throws {
        let disk = SimulatedFileSystem()
        try disk.createDirectory("/d")
        let journal = try Journal.open(at: "/d/j", fileSystem: disk)
        try journal.append(bytes("committed"))
        let committedEnd = journal.byteCount
        try journal.append(batch: [[UInt8](repeating: 0x41, count: 5000), [UInt8](repeating: 0x42, count: 5000), bytes("last")])
        try journal.close()
        let file = try disk.open("/d/j", mode: .readWrite)
        try disk.write(file, [UInt8](repeating: 0, count: 4096 - committedEnd), at: committedEnd)
        try disk.fullSync(file)
        try disk.close(file)

        let reopened = try Journal.open(at: "/d/j", fileSystem: disk)
        #expect(try reopened.replay().records.map(\.sequence) == [1])
        #expect(reopened.openReport.corruption.isEmpty)
        #expect(reopened.byteCount == committedEnd)
    }

    /// Damage inside a batch that a later append follows is damage in the
    /// middle: the batch was acknowledged, so what of it verifies is kept.
    @Test(.failureMode("design/15", "a byte flips in the middle of the log"))
    func damageInsideAnEarlierBatchCostsOnlyTheDamagedRecord() throws {
        let disk = SimulatedFileSystem()
        try disk.createDirectory("/d")
        let journal = try Journal.open(at: "/d/j", fileSystem: disk)
        try journal.append(batch: [bytes("one"), bytes("two"), bytes("three")])
        try journal.append(bytes("after"))
        try journal.close()
        try flipBit(in: "/d/j", at: Journal.headerSize + 3 + 12, using: disk)   // inside "two"
        let reopened = try Journal.open(at: "/d/j", fileSystem: disk)
        #expect(payloads(try reopened.replay()) == ["one", "three", "after"])
        #expect(reopened.openReport.corruption.map(\.lostRecords) == [1])
        #expect(reopened.openReport.corruption.first?.firstLostSequence == 2)
        #expect(reopened.openReport.droppedBytes == 0)
    }

    /// The bytes an earlier release wrote for `append("alpha")`,
    /// `append(batch: ["bravo", "charlie", "delta"])`, `append("echo")`:
    /// records with no batch bits, which must read exactly as they did.
    static let logWrittenByAnEarlierRelease: [UInt8] = [
        0x0D, 0x00, 0x00, 0x00, 0xF0, 0x16, 0xF1, 0x06, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x61, 0x6C, 0x70, 0x68,
        0x61, 0x0D, 0x00, 0x00, 0x00, 0xDA, 0x1D, 0x54, 0x76, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x62, 0x72, 0x61,
        0x76, 0x6F, 0x0F, 0x00, 0x00, 0x00, 0x33, 0x0A, 0xD7, 0x17, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x63, 0x68,
        0x61, 0x72, 0x6C, 0x69, 0x65, 0x0D, 0x00, 0x00, 0x00, 0xF3, 0x63, 0x48, 0x3C, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x64, 0x65, 0x6C, 0x74, 0x61, 0x0C, 0x00, 0x00, 0x00, 0xB7, 0xBF, 0x91, 0xCD, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x65, 0x63, 0x68, 0x6F,
    ]

    @Test func aLogAnEarlierReleaseWroteReadsAsItDid() throws {
        let disk = SimulatedFileSystem()
        try disk.createDirectory("/d")
        let file = try disk.open("/d/j", mode: .createExclusive)
        try disk.write(file, Self.logWrittenByAnEarlierRelease, at: 0)
        try disk.fullSync(file)
        try disk.close(file)
        try disk.syncDirectory("/d")

        let journal = try Journal.open(at: "/d/j", fileSystem: disk)
        #expect(payloads(try journal.replay()) == ["alpha", "bravo", "charlie", "delta", "echo"])
        #expect(try journal.replay().records.map(\.sequence) == [1, 2, 3, 4, 5])
        #expect(journal.openReport == .init(droppedBytes: 0, staleRecords: 0, records: 5))
        // A single record is still written exactly as an earlier release wrote it.
        #expect(Journal.frame(bytes("echo"), sequence: 5) == Array(Self.logWrittenByAnEarlierRelease.suffix(Journal.headerSize + 4)))
        #expect(try journal.append(bytes("foxtrot")) == 6)
    }

    @Test func aBatchsRecordsAreTiedTogetherAndASingleRecordIsNot() {
        func field(_ frame: [UInt8]) -> UInt32 { frame.prefix(4).enumerated().reduce(0) { $0 | UInt32($1.element) << ($1.offset * 8) } }
        #expect(field(Journal.frame(bytes("x"), sequence: 1)) & ~Journal.lengthMask == 0)
        #expect(field(Journal.frame(bytes("x"), sequence: 1, more: true)) & ~Journal.lengthMask == Journal.moreFlag)
        #expect(field(Journal.frame(bytes("x"), sequence: 2, more: true, joined: true)) & ~Journal.lengthMask == Journal.moreFlag | Journal.joinedFlag)
        // A batch read whole; the same records without their last are a torn tail.
        let batch = Journal.frame(bytes("a"), sequence: 1, more: true) + Journal.frame(bytes("b"), sequence: 2, more: true, joined: true)
            + Journal.frame(bytes("c"), sequence: 3, joined: true)
        #expect(Journal.scan(batch, maxRecordSize: 1 << 20).records.map(\.sequence) == [1, 2, 3])
        let cut = Array(batch.dropLast(Journal.headerSize + 1))
        #expect(Journal.scan(cut, maxRecordSize: 1 << 20).records.isEmpty)
        #expect(Journal.scan(cut, maxRecordSize: 1 << 20).validEnd == 0)
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

    @Test(.failureMode("design/15", "compact runs over a log with skipped damage")) func compactingKeepsACopyOfTheDamagedLogBeforeItIsTruncated() throws {
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

    @Test(.failureMode("design/15", "a crash tears the last record or leaves a hole")) func aHoleOfZerosIsNeverARecord() throws {
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

    @Test(.failureMode("design/15", "a record exceeds maxRecordSize")) func aRecordLargerThanTheLimitIsRefused() throws {
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

    @Test(.failureMode("design/15", "the snapshot fails its checksum")) func aCorruptSnapshotIsQuarantinedAndEveryOpenRefuses() throws {
        let dir = try TempDirectory()
        var journal = try Journal.open(at: dir.file("j"))
        try journal.append(bytes("a"))
        try journal.compact(snapshot: bytes("a"))
        try journal.append(bytes("b"))
        try journal.close()
        try flipBit(in: dir.file("j.snapshot"), at: 25)
        let error = #expect(throws: StoreError.self) { try Journal.open(at: dir.file("j")) }
        #expect(error?.kind == .corrupt)
        #expect(try fs.list(directory: dir.path).contains("j.snapshot.corrupt-1"))
        // The snapshot is gone from its place, but the loss is not forgotten:
        // a retried open, or the next launch, refuses too.
        let again = #expect(throws: StoreError.self) { try Journal.open(at: dir.file("j")) }
        #expect(again?.kind == .corrupt)
        // Until the app accepts the loss, and sees it reported.
        journal = try Journal.open(at: dir.file("j"), options: .init(lostSnapshot: .acceptLoss))
        #expect(journal.openReport.lostSnapshot)
        #expect(payloads(try journal.replay()) == ["b"])
        #expect(try journal.replay().snapshot == nil)
        #expect(try journal.append(bytes("c")) == 3)
        try journal.close()
        // Accepted once is accepted.
        journal = try Journal.open(at: dir.file("j"))
        #expect(!journal.openReport.lostSnapshot)
        #expect(payloads(try journal.replay()) == ["b", "c"])
    }

    @Test(.failureMode("design/15", "the snapshot fails its checksum")) func theLossIsRecordedBeforeTheSnapshotIsMovedAside() async throws {
        let corrupted: (SimulatedFileSystem) throws -> Void = { disk in
            try disk.createDirectory("/d")
            let journal = try Journal.open(at: "/d/j", fileSystem: disk)
            try journal.append(bytes("a"))
            try journal.compact(snapshot: bytes("a"))
            try journal.close()
            let file = try disk.open("/d/j.snapshot", mode: .readWrite)
            try disk.write(file, [0xFF], at: 25)
            try disk.fullSync(file)
            try disk.close(file)
        }
        let report = try await exploreCrashes("a refused open", setup: corrupted, operation: { disk in
            _ = try? Journal.open(at: "/d/j", fileSystem: disk)
        }) { disk, _ in
            do throws(StoreError) {
                _ = try Journal.open(at: "/d/j", fileSystem: disk)
                return "a journal whose snapshot was lost opened without being asked to accept it"
            } catch {
                return error.kind == .corrupt ? nil : "open threw \(error)"
            }
        }
        #expect(report.violations.isEmpty, "\(report)")
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

    @Test(.failureMode("design/15", "append's write fails (ENOSPC)")) func aFailedWriteIsRolledBackAndTheJournalKeepsWorking() throws {
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

    @Test(.failureMode("design/15", "append's fullSync fails")) func aFailedFullSyncPoisonsTheJournalUntilItIsReopened() throws {
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
        #expect(try journal.replay().records.map { text($0.bytes) } == ["a"])
        try journal.append(bytes("d"))
    }

    /// The record whose sync failed must not come back as committed. Reopen,
    /// append a later record, and crash: replay is a prefix of what was synced,
    /// with no zero-filled hole and without the failed record.
    @Test(.failureMode("design/15", "append's fullSync fails"))
    func aFailedFullSyncNeverComesBackAndALaterAppendLeavesAPrefix() throws {
        let disk = try disk()
        var journal = try Journal.open(at: "/d/j", fileSystem: disk)
        try journal.append(bytes("a"))
        disk.inject(5, on: .fullSync)   // EIO
        let error = #expect(throws: StoreError.self) { try journal.append(bytes("b")) }
        #expect(error?.kind == .ioFailure)
        let poisoned = #expect(throws: StoreError.self) { try journal.replay() }
        #expect(poisoned?.kind == .poisoned)
        try journal.close()

        journal = try Journal.open(at: "/d/j", fileSystem: disk)
        let reported = try journal.replay().records.map { text($0.bytes) }
        #expect(reported == ["a"])
        #expect(journal.openReport.corruption.isEmpty)
        #expect(journal.openReport.droppedBytes == 0)

        // Power loss with nothing further appended keeps the prefix reopen reported.
        let lost = disk.fork()
        lost.crash()
        let afterLoss = try Journal.open(at: "/d/j", fileSystem: lost)
        #expect(try afterLoss.replay().records.map { text($0.bytes) } == reported)
        #expect(afterLoss.openReport.corruption.isEmpty)
        try afterLoss.close()

        try journal.append(bytes("d"))
        try journal.close()
        disk.crash()

        journal = try Journal.open(at: "/d/j", fileSystem: disk)
        let replay = try journal.replay()
        let found = replay.records.map { text($0.bytes) }
        let synced = ["a", "d"]
        #expect(found == Array(synced.prefix(found.count)) && !found.contains("b"))
        #expect(found == synced)
        #expect(replay.records.map(\.sequence) == [1, 2])
        #expect(journal.openReport.corruption.isEmpty)
        #expect(journal.openReport.droppedBytes == 0)
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
