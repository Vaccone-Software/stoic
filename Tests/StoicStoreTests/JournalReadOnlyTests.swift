import Foundation
@testable import StoicStore
import StoicTesting
import Synchronization
import Testing

@Suite("Journal read-only replay")
struct JournalReadOnlyTests {
    static let path = "/d/journal"

    /// The records a replay stands for, snapshot first, as strings.
    static func records(_ replay: Journal.Replay) -> [String] {
        let folded = replay.snapshot.map { text($0.bytes).split(separator: "|").map(String.init) } ?? []
        return folded + replay.records.map { text($0.bytes) }
    }

    static func fold(_ replay: Journal.Replay) -> [UInt8] { bytes(records(replay).joined(separator: "|")) }

    static func disk() throws -> SimulatedFileSystem {
        let disk = SimulatedFileSystem()
        try disk.createDirectory("/d")
        return disk
    }

    @Test func itSeesWhatTheWriterWroteAndWhatOpenWouldReplay() throws {
        let disk = try Self.disk()
        let journal = try Journal.open(at: Self.path, fileSystem: disk)
        try journal.append(bytes("a"))
        try journal.append(batch: [bytes("b"), bytes("c")])
        try journal.compact(Self.fold)
        try journal.append(bytes("d"))

        let seen = try Journal.readOnlyReplay(at: Self.path, fileSystem: disk)
        #expect(Self.records(seen.replay) == ["a", "b", "c", "d"])
        #expect(seen.replay.snapshot?.through == 3)
        #expect(seen.replay.records.map(\.sequence) == [4])
        #expect(seen.report == .init(droppedBytes: 0, staleRecords: 0, records: 1))
        #expect(seen.replay == (try journal.replay()))
        try journal.close()
    }

    @Test(.failureMode("design/15", "a second process reads the log while another appends"))
    func aReaderChangesNothingOnDisk() throws {
        let disk = try Self.disk()
        let journal = try Journal.open(at: Self.path, fileSystem: disk)
        try journal.append(bytes("one"))
        try journal.compact(Self.fold)
        try journal.append(bytes("two"))
        try journal.append(bytes("three"))
        let before = disk.files
        let operations = disk.operationCount

        _ = try Journal.readOnlyReplay(at: Self.path, fileSystem: disk)

        #expect(disk.files == before)
        #expect(disk.operationCount == operations, "not one create, write, truncate, sync, rename or remove")
        // The writer is undisturbed: its next append lands where it should.
        try journal.append(bytes("four"))
        try journal.close()
        let reopened = try Journal.open(at: Self.path, fileSystem: disk)
        #expect(Self.records(try reopened.replay()) == ["one", "two", "three", "four"])
        #expect(reopened.openReport.droppedBytes == 0)
    }

    @Test(.failureMode("design/15", "a reader finds a torn tail"), arguments: [1, 9, 17, 22])
    func aTornTailIsIgnoredReportedAndLeftInTheFile(cut: Int) throws {
        let disk = try Self.disk()
        let journal = try Journal.open(at: Self.path, fileSystem: disk)
        try journal.append(bytes("first"))
        let intact = journal.byteCount
        try journal.append(bytes("second-record"))
        try journal.close()
        let file = try disk.open(Self.path, mode: .readWrite)
        try disk.truncate(file, to: intact + cut)
        try disk.close(file)
        let before = disk.files

        let seen = try Journal.readOnlyReplay(at: Self.path, fileSystem: disk)
        #expect(Self.records(seen.replay) == ["first"])
        #expect(seen.report.droppedBytes == cut)
        #expect(disk.files == before, "a reader cuts nothing: the bytes may be an append in flight")
    }

    @Test func aJournalThatDoesNotExistReadsAsEmptyAndIsNotCreated() throws {
        let disk = try Self.disk()
        let seen = try Journal.readOnlyReplay(at: Self.path, fileSystem: disk)
        #expect(seen.replay == .init(snapshot: nil, records: []))
        #expect(disk.files.isEmpty)
    }

    @Test(.failureMode("design/15", "a reader finds a lost snapshot"))
    func aLostSnapshotIsRefusedNotQuarantinedAndAcceptedOnlyOnRequest() throws {
        let disk = try Self.disk()
        let journal = try Journal.open(at: Self.path, fileSystem: disk)
        try journal.append(bytes("a"))
        try journal.compact(Self.fold)
        try journal.append(bytes("b"))
        try journal.close()
        let snapshot = Self.path + ".snapshot"
        var damaged = disk.contents(of: snapshot)!
        damaged[damaged.count - 1] ^= 0x10
        let file = try disk.open(snapshot, mode: .readWrite)
        try disk.write(file, damaged, at: 0)
        try disk.close(file)
        let before = disk.files

        let error = #expect(throws: StoreError.self) { try Journal.readOnlyReplay(at: Self.path, fileSystem: disk) }
        #expect(error?.kind == .corrupt)
        #expect(disk.files == before, "the corrupt snapshot is where it was: only the writer's open moves it aside")

        let accepted = try Journal.readOnlyReplay(at: Self.path, fileSystem: disk, options: .init(lostSnapshot: .acceptLoss))
        #expect(accepted.report.lostSnapshot)
        #expect(Self.records(accepted.replay) == ["b"])
        #expect(disk.files == before)
    }

    @Test func damageInTheMiddleIsReportedAndRefusedOnRequest() throws {
        let disk = try Self.disk()
        let journal = try Journal.open(at: Self.path, fileSystem: disk)
        var starts: [Int] = []
        for index in 0..<10 {
            starts.append(journal.byteCount)
            try journal.append(bytes("record-\(index)"))
        }
        try journal.close()
        var log = disk.contents(of: Self.path)!
        log[starts[4] + 20] ^= 0x10
        let file = try disk.open(Self.path, mode: .readWrite)
        try disk.write(file, log, at: 0)
        try disk.close(file)

        let seen = try Journal.readOnlyReplay(at: Self.path, fileSystem: disk)
        #expect(seen.replay.records.count == 9)
        #expect(seen.report.corruptRecords == 1)
        let error = #expect(throws: StoreError.self) {
            try Journal.readOnlyReplay(at: Self.path, fileSystem: disk, options: .init(middleDamage: .refuse))
        }
        #expect(error?.kind == .corrupt)
    }

    /// A reader on every disk the writer's crash could leave behind, which
    /// includes everything a concurrent reader could see: it finds a prefix of
    /// what was appended, in order, never an error and never a gap, and it
    /// leaves the disk as it found it.
    @Test(.failureMode("design/15", "a second process reads the log while another appends"))
    func aReaderOnEveryCrashImageSeesAPrefixAndChangesNothing() async throws {
        let names = ["r1", "r2", "r3", "r4", "r5", "r6"]
        let report = try await exploreCrashes(
            "Journal.readOnlyReplay",
            setup: { disk in try disk.createDirectory("/d") },
            operation: { disk in
                let journal = try Journal.open(at: Self.path, fileSystem: disk)
                try journal.append(bytes(names[0]))
                try journal.append(batch: [bytes(names[1]), bytes(names[2])])
                try journal.compact(Self.fold)
                try journal.append(bytes(names[3]))
                try journal.append(bytes(names[4]))
                try journal.compact(Self.fold)
                try journal.append(bytes(names[5]))
                try journal.close()
            },
            check: { disk, _ in
                let before = disk.files
                let seen = try Journal.readOnlyReplay(at: Self.path, fileSystem: disk)
                let found = Self.records(seen.replay)
                guard found == Array(names.prefix(found.count)) else { return "read \(found), not a prefix of \(names)" }
                guard disk.files == before else { return "the read changed the disk" }
                guard seen.report.corruption.isEmpty else { return "a crash was reported as damage in the middle: \(seen.report.corruption)" }
                return nil
            }
        )
        print(report)
        #expect(report.violations.isEmpty, "\(report.violations.prefix(3).map(\.description).joined(separator: "\n"))")
    }

    /// The real thing: a writer appending and compacting on the real file
    /// system while another reader looks again and again. Every look is one
    /// consistent state, none goes backwards, and the writer's file is intact
    /// afterwards (a reader that cut a torn tail would have shown here).
    @Test(.failureMode("design/15", "a second process reads the log while another appends"))
    func aConcurrentReaderNeverSeesAGapAndNeverDisturbsTheWriter() async throws {
        let dir = try TempDirectory()
        let path = dir.file("journal")
        let total = 60
        let journal = try Journal.open(at: path)
        let finished = Atomic<Bool>(false)

        async let writing: Void = Task.detached {
            for index in 1...total {
                try journal.append(bytes("r\(index)"))
                if index == total / 2 { try journal.compact(Self.fold) }
            }
            finished.store(true, ordering: .releasing)
        }.value
        async let reading: [Int] = Task.detached {
            var counts: [Int] = []
            repeat {
                let seen = try Journal.readOnlyReplay(at: path)
                let found = Self.records(seen.replay)
                let expected = (0..<found.count).map { "r\($0 + 1)" }
                #expect(found == expected, "a read saw \(found.count) records that are not a prefix")
                counts.append(found.count)
            } while !finished.load(ordering: .acquiring)
            return counts
        }.value
        let counts = try await reading
        try await writing

        #expect(counts == counts.sorted(), "a later read saw fewer records than an earlier one")
        let last = try Journal.readOnlyReplay(at: path)
        #expect(Self.records(last.replay).count == total)
        try journal.close()
        let reopened = try Journal.open(at: path)
        #expect(reopened.openReport.droppedBytes == 0)
        #expect(reopened.openReport.corruption.isEmpty)
        #expect(Self.records(try reopened.replay()).count == total)
    }

    /// The reader reads the log, then the snapshot; a compaction between the
    /// two reads must cost it nothing. Read the other way round, the reader
    /// would pair a snapshot from before the compaction (none) with a log from
    /// after it (empty), and report that the three records never existed.
    @Test(.failureMode("design/15", "a second process reads the log while another appends"))
    func aCompactionBetweenTheReadersTwoReadsLosesNothing() throws {
        let disk = try Self.disk()
        let journal = try Journal.open(at: Self.path, fileSystem: disk)
        try journal.append(batch: [bytes("a"), bytes("b"), bytes("c")])
        let compacted = SendableBox(false)
        let reader = BetweenReads(disk) {
            compacted.mutate { $0 = true }
            try? journal.compact(Self.fold)
        }

        let seen = try Journal.readOnlyReplay(at: Self.path, fileSystem: reader)
        #expect(compacted.value, "the compaction did run between the two reads")
        #expect(Self.records(seen.replay) == ["a", "b", "c"])
        #expect(seen.report.corruption.isEmpty)
    }

    // MARK: Sequences a layer above can rely on

    @Test func aReplaysLastSequenceIsTheJournalsLastSequenceInEveryState() throws {
        let disk = try Self.disk()
        var journal = try Journal.open(at: Self.path, fileSystem: disk)
        func agree() throws {
            #expect(try journal.replay().lastSequence == journal.lastSequence)
        }
        try agree()                                        // empty
        try journal.append(bytes("a"))
        try journal.append(batch: [bytes("b"), bytes("c")])
        try agree()                                        // records only
        try journal.compact(Self.fold)
        try agree()                                        // snapshot only
        try journal.append(bytes("d"))
        try agree()                                        // snapshot and records
        try journal.close()
        journal = try Journal.open(at: Self.path, fileSystem: disk)
        try agree()                                        // after a reopen
        try journal.close()

        // An interrupted compaction: the snapshot is durable, the log is stale.
        let stale = try Self.disk()
        let writer = try Journal.open(at: Self.path, fileSystem: stale)
        try writer.append(batch: [bytes("x"), bytes("y")])
        let log = stale.contents(of: Self.path)!
        try writer.compact(Self.fold)
        try writer.close()
        let file = try stale.open(Self.path, mode: .readWrite)
        try stale.write(file, log, at: 0)
        try stale.close(file)
        journal = try Journal.open(at: Self.path, fileSystem: stale)
        try agree()
        try journal.close()
    }

    @Test func buildingAppendTellsTheFirstSequenceUnderTheLockAndDeclinesByReturningNothing() throws {
        let disk = try Self.disk()
        let journal = try Journal.open(at: Self.path, fileSystem: disk)
        try journal.append(bytes("a"))
        let told = SendableBox<[UInt64]>([])
        let numbers = try journal.append(building: { first in
            told.mutate { $0.append(first) }
            return [bytes("b@\(first)"), bytes("c@\(first + 1)")]
        })
        #expect(numbers == [2, 3])
        #expect(told.value == [2])
        #expect(try journal.append(building: { _ in [] }) == [])
        #expect(journal.lastSequence == 3, "declining wrote nothing")
        #expect(try journal.replay().records.map { text($0.bytes) } == ["a", "b@2", "c@3"])

        let tooBig = Journal.Options(maxRecordSize: 4)
        let small = try Journal.open(at: "/d/small", fileSystem: disk, options: tooBig)
        let error = #expect(throws: StoreError.self) { try small.append(building: { _ in [bytes("12345")] }) }
        #expect(error?.kind == .invalidArgument)
        #expect(small.lastSequence == 0)
    }

    @Test func compactingWithSequenceTellsTheFoldTheSequenceItIsRecordedAgainst() throws {
        let disk = try Self.disk()
        let journal = try Journal.open(at: Self.path, fileSystem: disk)
        try journal.append(batch: [bytes("a"), bytes("b"), bytes("c")])
        let told = SendableBox<[UInt64]>([])
        try journal.compact(withSequence: { replay, through in
            told.mutate { $0.append(through) }
            return Self.fold(replay)
        })
        #expect(told.value == [3])
        #expect(try journal.replay().snapshot?.through == 3)
    }
}

/// A file system that runs `between` once, as the first file a reader opened
/// is closed: the moment between its first read and its second.
final class BetweenReads: FileSystem {
    private let base: SimulatedFileSystem
    private let between: @Sendable () -> Void
    private let opened = Mutex<Set<Int32>>([])
    private let fired = Mutex(false)

    init(_ base: SimulatedFileSystem, between: @escaping @Sendable () -> Void) {
        self.base = base
        self.between = between
    }

    func open(_ path: String, mode: OpenMode) throws(StoreError) -> OpenFile {
        let file = try base.open(path, mode: mode)
        if mode == .read { opened.withLock { _ = $0.insert(file.rawValue) } }
        return file
    }
    func close(_ file: OpenFile) throws(StoreError) {
        try base.close(file)
        let wasRead = opened.withLock { $0.remove(file.rawValue) != nil }
        if wasRead, !fired.withLock({ let was = $0; $0 = true; return was }) { between() }
    }
    func read(_ file: OpenFile, at offset: Int, count: Int) throws(StoreError) -> [UInt8] { try base.read(file, at: offset, count: count) }
    func write(_ file: OpenFile, _ bytes: [UInt8], at offset: Int) throws(StoreError) { try base.write(file, bytes, at: offset) }
    func size(of file: OpenFile) throws(StoreError) -> Int { try base.size(of: file) }
    func truncate(_ file: OpenFile, to size: Int) throws(StoreError) { try base.truncate(file, to: size) }
    func fullSync(_ file: OpenFile) throws(StoreError) { try base.fullSync(file) }
    func syncDirectory(_ directory: String) throws(StoreError) { try base.syncDirectory(directory) }
    func rename(from source: String, to destination: String) throws(StoreError) { try base.rename(from: source, to: destination) }
    func remove(_ path: String) throws(StoreError) { try base.remove(path) }
    func list(directory: String) throws(StoreError) -> [String] { try base.list(directory: directory) }
    func exists(_ path: String) throws(StoreError) -> Bool { try base.exists(path) }
    func freeSpace(at directory: String) throws(StoreError) -> UInt64 { try base.freeSpace(at: directory) }
    func createDirectory(_ path: String) throws(StoreError) { try base.createDirectory(path) }
}
