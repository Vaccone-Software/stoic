#if STOIC_CRYPTO
import Dispatch
import Foundation
import Stoic
@testable import StoicSealed
@testable import StoicStore
import StoicTesting
import Testing

@Suite("SealedJournal")
struct SealedJournalTests {
    static let path = "/d/log"
    static let context = SealContext("app.log", "main")

    static func disk() throws -> SimulatedFileSystem {
        let disk = SimulatedFileSystem()
        try disk.createDirectory("/d")
        return disk
    }

    static func open(_ disk: SimulatedFileSystem, _ ring: Keyring, context: SealContext = context) throws -> SealedJournal {
        try SealedJournal.open(at: path, context: context, keyring: ring, fileSystem: disk)
    }

    /// What a replay stands for, snapshot first: the folded items (joined by
    /// `|`) and the records after them.
    static func items(_ replay: SealedJournal.Replay) -> [String] {
        (replay.snapshot.map { text($0.bytes).split(separator: "|").map(String.init) } ?? []) + replay.records.map { text($0.bytes) }
    }

    static func fold(_ replay: SealedJournal.Replay) -> [UInt8] { bytes(items(replay).joined(separator: "|")) }

    /// The log as the journal underneath stores it: each record's sealed
    /// bytes, by sequence.
    static func storedRecords(_ disk: SimulatedFileSystem) throws -> [(sequence: UInt64, bytes: [UInt8])] {
        try Journal.readOnlyReplay(at: path, fileSystem: disk).replay.records.map { ($0.sequence, $0.bytes) }
    }

    /// Replaces the log with these records, each framed validly: an attacker
    /// who edits sealed bytes and fixes the checksums, which the journal's CRC
    /// does nothing against and the seal must.
    static func rewriteLog(_ disk: SimulatedFileSystem, _ records: [(sequence: UInt64, bytes: [UInt8])]) throws {
        let image = records.flatMap { Journal.frame($0.bytes, sequence: $0.sequence) }
        let file = try disk.open(path, mode: .readWrite)
        try disk.truncate(file, to: 0)
        try disk.write(file, image, at: 0)
        try disk.fullSync(file)
        try disk.close(file)
    }

    // MARK: Round trip

    @Test(.failureMode("design/24", "records are appended and replayed"))
    func recordsRoundTripAndTheFileHoldsNoPlaintext() throws {
        let disk = try Self.disk()
        let (ring, _) = try makeRing()
        var journal = try Self.open(disk, ring)
        #expect(try journal.append(bytes("SECRET-ONE")) == 1)
        #expect(try journal.append(batch: [bytes("SECRET-TWO"), bytes("SECRET-THREE")]) == [2, 3])
        #expect(try journal.append(batch: []) == [])
        let replay = try journal.replay()
        #expect(replay.records.map { text($0.bytes) } == ["SECRET-ONE", "SECRET-TWO", "SECRET-THREE"])
        #expect(replay.records.map(\.sequence) == [1, 2, 3])
        #expect(replay.isComplete && replay.snapshot == nil)
        #expect(filesHolding(bytes("SECRET"), on: disk).isEmpty, "the log is ciphertext")
        try journal.close()

        journal = try Self.open(disk, ring)
        #expect(try journal.replay().records.map { text($0.bytes) } == ["SECRET-ONE", "SECRET-TWO", "SECRET-THREE"])
        #expect(try journal.append(bytes("four")) == 4)
        #expect(journal.lastSequence == 4)
        try journal.close()
    }

    @Test func eachRecordCostsTheSealPlusTheJournalFrame() throws {
        let disk = try Self.disk()
        let (ring, _) = try makeRing()
        let journal = try Self.open(disk, ring)
        try journal.append(Array(repeating: 7, count: 24))
        #expect(journal.byteCount == 16 + 24 + Sealing.overhead, "a 24-byte record is 90 bytes in the log")
    }

    @Test func aBatchTooLargeIsRefusedAndNothingIsWritten() throws {
        let disk = try Self.disk()
        let (ring, _) = try makeRing()
        let journal = try SealedJournal.open(
            at: Self.path, context: Self.context, keyring: ring, fileSystem: disk, options: .init(maxRecordSize: 100)
        )
        do throws(SealedStoreError) { try journal.append(batch: [bytes("ok"), Array(repeating: 1, count: 60)]) } catch {
            if case .store(let store) = error { #expect(store.kind == .invalidArgument) } else { Issue.record("\(error)") }
        }
        #expect(journal.lastSequence == 0 && journal.byteCount == 0)
    }

    @Test func aDestroyedKeyringAppendsNothing() throws {
        let disk = try Self.disk()
        let (ring, _) = try makeRing()
        let journal = try Self.open(disk, ring)
        try journal.append(bytes("a"))
        let before = disk.files
        try ring.destroy()
        do throws(SealedStoreError) { try journal.append(bytes("b")) } catch {
            if case .keyring(.destroyed) = error {} else { Issue.record("\(error)") }
        }
        #expect(disk.files == before)
        #expect(journal.lastSequence == 1)
    }

    // MARK: Torn tail

    @Test(.failureMode("design/24", "a sealed journal has a torn tail"), arguments: [3, 12, 17, 30, 60])
    func aTornTailIsCutAtOpenAndTheRecordsBeforeItOpen(cutAt: Int) throws {
        let disk = try Self.disk()
        let (ring, _) = try makeRing()
        var journal = try Self.open(disk, ring)
        try journal.append(bytes("first"))
        let intact = journal.byteCount
        try journal.append(bytes("second-record"))
        try journal.close()
        let file = try disk.open(Self.path, mode: .readWrite)
        try disk.truncate(file, to: intact + cutAt)
        try disk.close(file)

        journal = try Self.open(disk, ring)
        #expect(journal.openReport.droppedBytes == cutAt, "the journal says what it cut")
        let replay = try journal.replay()
        #expect(replay.records.map { text($0.bytes) } == ["first"])
        #expect(replay.isComplete, "a torn tail is not a failed record")
        #expect(replay.report.droppedBytes == cutAt)
        #expect(try journal.append(bytes("third")) == 2)
    }

    // MARK: A record that fails does not hide the others

    @Test(.failureMode("design/24", "a record in the middle of a sealed journal is altered"))
    func oneTamperedRecordIsReportedWithItsSequenceAndTheOthersAreReturned() throws {
        let disk = try Self.disk()
        let (ring, _) = try makeRing()
        var journal = try Self.open(disk, ring)
        for index in 1...5 { try journal.append(bytes("record-\(index)")) }
        try journal.close()
        var stored = try Self.storedRecords(disk)
        stored[2].bytes[40] ^= 0x01        // inside record 3's ciphertext; the frame is rewritten with a valid checksum
        try Self.rewriteLog(disk, stored)

        journal = try Self.open(disk, ring)
        #expect(journal.openReport.corruption.isEmpty, "the journal's own checks cannot see it")
        let replay = try journal.replay()
        #expect(replay.records.map { text($0.bytes) } == ["record-1", "record-2", "record-4", "record-5"])
        #expect(replay.records.map(\.sequence) == [1, 2, 4, 5])
        #expect(replay.failures == [.init(item: .record(sequence: 3), error: .tampered)])
        #expect(!replay.isComplete)
    }

    @Test(.failureMode("design/24", "a sealed record is moved, repeated or swapped"))
    func aRecordMovedRepeatedOrSwappedDoesNotOpenAtItsNewPlace() throws {
        let disk = try Self.disk()
        let (ring, _) = try makeRing()
        var journal = try Self.open(disk, ring)
        for index in 1...4 { try journal.append(bytes("record-\(index)")) }
        try journal.close()
        let stored = try Self.storedRecords(disk)

        // Swap 2 and 3; repeat 1 as 5.
        var edited = stored
        edited[1].bytes = stored[2].bytes
        edited[2].bytes = stored[1].bytes
        edited.append((5, stored[0].bytes))
        try Self.rewriteLog(disk, edited)
        journal = try Self.open(disk, ring)
        let replay = try journal.replay()
        #expect(replay.records.map(\.sequence) == [1, 4], "only the records that are where they were sealed to be")
        #expect(Set(replay.failures.map(\.item)) == [.record(sequence: 2), .record(sequence: 3), .record(sequence: 5)])
        #expect(replay.failures.allSatisfy { $0.error == .tampered })
        try journal.close()

        // A record of another journal, with the right sequence number.
        let other = try Self.disk()
        let foreign = try SealedJournal.open(at: Self.path, context: SealContext("app.log", "other"), keyring: ring, fileSystem: other)
        for index in 1...4 { try foreign.append(bytes("foreign-\(index)")) }
        try foreign.close()
        try Self.rewriteLog(disk, try Self.storedRecords(other))
        journal = try Self.open(disk, ring)
        #expect(try journal.replay().records.isEmpty, "another journal's records are another context")
        #expect(try journal.replay().failures.count == 4)
    }

    @Test func aPlaintextRecordIsNotSealedAndAKeyThatIsGoneIsUnknown() throws {
        let disk = try Self.disk()
        let (ring, _) = try makeRing()
        var journal = try Self.open(disk, ring)
        try journal.append(bytes("sealed"))
        try journal.close()
        var stored = try Self.storedRecords(disk)
        stored.append((2, bytes("a plaintext record")))
        let stranger = try Sealing.seal(bytes("x"), context: Self.context.deriving(.journalRecord, number: 3), key: .generate())
        stored.append((3, stranger))
        try Self.rewriteLog(disk, stored)
        journal = try Self.open(disk, ring)
        let replay = try journal.replay()
        #expect(replay.records.map { text($0.bytes) } == ["sealed"])
        #expect(replay.failures.count == 2)
        #expect(replay.failures[0] == .init(item: .record(sequence: 2), error: .notSealed))
        if case .unknownKey = replay.failures[1].error, replay.failures[1].item == .record(sequence: 3) {} else { Issue.record("\(replay.failures[1])") }
    }

    @Test(.failureMode("design/24", "the key of a sealed journal is lost"))
    func aLostKeyIsReportedPerRecordAndNothingIsDeletedOrOpenedAsEmpty() throws {
        let disk = try Self.disk()
        let (ring, custody) = try makeRing()
        let journal = try Self.open(disk, ring)
        for index in 1...3 { try journal.append(bytes("record-\(index)")) }
        try journal.compact(snapshot: bytes("folded"))
        try journal.append(bytes("after"))
        try journal.close()
        try custody.delete(name: "test.keyring")           // the custody item is gone with the device, say
        let before = disk.files

        let replacement = try Keyring.open(name: "test.keyring", custody: custody, ifMissing: .create)
        #expect(replacement.created, "an app sees this and knows the old data cannot be read")
        let events = RecordingInstrumentation()
        let replay = try withAmbient({ $0.instrumentation = events }) {
            try Self.open(disk, replacement.keyring).replay()
        }
        #expect(replay.snapshot == nil && replay.records.isEmpty)
        #expect(replay.failures.count == 2, "the snapshot and the one record after it")
        #expect(replay.failures.allSatisfy { if case .unknownKey = $0.error { true } else { false } })
        #expect(replay.failures.map(\.item) == [.snapshot(through: 3), .record(sequence: 4)])
        #expect(disk.files == before, "the data is exactly where it was: the key is what is missing")
        let event = try #require(events.events(named: "sealed.records_unreadable").first)
        #expect(event["unknownKey"].map(\.description) == "2" && event["snapshot"].map(\.description) == "true")
    }

    @Test func anotherContextOpensNothing() throws {
        let disk = try Self.disk()
        let (ring, _) = try makeRing()
        let journal = try Self.open(disk, ring)
        try journal.append(bytes("a"))
        try journal.close()
        let wrong = try Self.open(disk, ring, context: SealContext("app.log", "not-main"))
        let replay = try wrong.replay()
        #expect(replay.records.isEmpty && replay.failures.count == 1 && replay.failures[0].error == .tampered)
    }

    // MARK: Snapshots

    @Test func aSnapshotIsSealedAndBoundToTheSequenceItCovers() throws {
        let disk = try Self.disk()
        let (ring, _) = try makeRing()
        var journal = try Self.open(disk, ring)
        try journal.append(batch: [bytes("a"), bytes("b"), bytes("c")])
        try journal.compact(Self.fold)
        try journal.append(bytes("d"))
        let replay = try journal.replay()
        let snapshot = try #require(replay.snapshot)
        #expect(snapshot.through == 3 && text(snapshot.bytes) == "a|b|c")
        #expect(replay.records.map { text($0.bytes) } == ["d"])
        #expect(filesHolding(bytes("a|b|c"), on: disk).isEmpty)
        try journal.close()

        // Edit the snapshot's sequence, with the envelope redone: bound, so it fails.
        let sealed = try #require(Journal.readOnlyReplay(at: Self.path, fileSystem: disk).replay.snapshot).bytes
        try AtomicFile(fileSystem: disk).write(littleEndian(UInt64(2)) + sealed, to: Self.path + ".snapshot")
        journal = try Self.open(disk, ring)
        let edited = try journal.replay()
        #expect(edited.snapshot == nil)
        #expect(edited.failures == [.init(item: .snapshot(through: 2), error: .tampered)])
        try journal.close()

        // Flip a bit of the sealed snapshot itself.
        var flipped = sealed
        flipped[36] ^= 1
        try AtomicFile(fileSystem: disk).write(littleEndian(UInt64(3)) + flipped, to: Self.path + ".snapshot")
        journal = try Self.open(disk, ring)
        let damaged = try journal.replay()
        #expect(damaged.failures == [.init(item: .snapshot(through: 3), error: .tampered)])
        #expect(damaged.records.map { text($0.bytes) } == ["d"], "the records after it are still returned")
    }

    // MARK: Rotation and shredding

    @Test(.failureMode("design/24", "a compaction rotates the key"))
    func compactingWithRotationMakesEverythingBeforeItUnreadableForever() throws {
        let disk = try Self.disk()
        let (ring, custody) = try makeRing()
        let journal = try Self.open(disk, ring)
        for index in 1...4 { try journal.append(bytes("SECRET-\(index)")) }
        let oldKey = try ring.current
        let oldLog = try #require(disk.contents(of: Self.path))

        try journal.compact(rotatingKey: true, Self.fold)

        // The ring: the old key is gone, from memory and from the custody.
        #expect(ring.keyIDs.count == 1 && ring.key(id: oldKey.id) == nil)
        let persisted = try RingFormat.decode(try #require(custody.contents(of: "test.keyring")))
        #expect(persisted.map(\.id) == ring.keyIDs)
        #expect(try !contains(#require(custody.contents(of: "test.keyring")), oldKey.exportedForWrapping()), "no trace of the old key in the custody")
        // The journal: one snapshot under the new key, and it reads.
        let replay = try journal.replay()
        #expect(Self.items(replay) == ["SECRET-1", "SECRET-2", "SECRET-3", "SECRET-4"] && replay.isComplete)
        #expect(try Sealing.keyID(of: try #require(Journal.readOnlyReplay(at: Self.path, fileSystem: disk).replay.snapshot).bytes) == ring.keyIDs[0])
        #expect(try journal.append(bytes("SECRET-5")) == 5, "and it goes on, under the new key")

        // Now read the OLD bytes with what remains. Put the pre-compaction log
        // back on a fresh disk: every record is ciphertext under a key nobody has.
        let before = try Self.disk()
        let file = try before.open(Self.path, mode: .readWriteCreate)
        try before.write(file, oldLog, at: 0)
        try before.fullSync(file)
        try before.close(file)
        let old = try Self.open(before, ring).replay()
        #expect(old.records.isEmpty, "no record before the compaction can be opened")
        #expect(old.failures.count == 4)
        #expect(old.failures.allSatisfy { $0.error == .unknownKey(oldKey.id) })
        for sequence in 1...4 {
            // Not even by hand: the key is not anywhere to be found.
            let sealed = try #require(try Self.storedRecords(before).first { $0.sequence == UInt64(sequence) }).bytes
            #expect(throws: SealError.unknownKey(oldKey.id)) {
                try Sealing.open(sealed, context: Self.context.deriving(.journalRecord, number: UInt64(sequence)), keyring: ring)
            }
        }
        #expect(filesHolding(bytes("SECRET"), on: disk).isEmpty && filesHolding(bytes("SECRET"), on: before).isEmpty)
    }

    @Test func aSecondRotationAlsoShredsTheFirstSnapshot() throws {
        let disk = try Self.disk()
        let (ring, _) = try makeRing()
        let journal = try Self.open(disk, ring)
        try journal.append(bytes("one"))
        try journal.compact(rotatingKey: true, Self.fold)
        // The snapshot file is an AtomicFile envelope (20 bytes), the sequence it covers (8), and the sealed value.
        let firstSnapshot = Array(try #require(disk.contents(of: Self.path + ".snapshot")).dropFirst(20 + 8))
        #expect(try Sealing.open(firstSnapshot, context: Self.context.deriving(.journalSnapshot, number: 1), keyring: ring) == bytes("one"))
        try journal.append(bytes("two"))
        try journal.compact(rotatingKey: true, Self.fold)
        #expect(Self.items(try journal.replay()) == ["one", "two"])
        #expect(ring.keyIDs.count == 1)
        // The first snapshot's bytes, read now: under a key that is gone.
        #expect(throws: SealError.self) {
            try Sealing.open(firstSnapshot, context: Self.context.deriving(.journalSnapshot, number: 1), keyring: ring)
        }
    }

    @Test(.failureMode("design/24", "a compaction finds records it cannot open"))
    func aCompactionRefusesToDestroyWhatItCannotRead() throws {
        let disk = try Self.disk()
        let (ring, _) = try makeRing()
        var journal = try Self.open(disk, ring)
        for index in 1...3 { try journal.append(bytes("record-\(index)")) }
        try journal.close()
        var stored = try Self.storedRecords(disk)
        stored[1].bytes[45] ^= 1
        try Self.rewriteLog(disk, stored)
        journal = try Self.open(disk, ring)
        let before = disk.files
        let keysBefore = ring.keyIDs

        do throws(SealedStoreError) { try journal.compact(snapshot: bytes("x")) } catch {
            if case .unreadable(let count) = error { #expect(count == 1) } else { Issue.record("\(error)") }
        }
        #expect(disk.files == before, "nothing was written")
        // With rotation it refuses too, and the old key is NOT retired: what it
        // could still read stays readable.
        do throws(SealedStoreError) { try journal.compact(snapshot: bytes("x"), rotatingKey: true) } catch {
            if case .unreadable = error {} else { Issue.record("\(error)") }
        }
        #expect(disk.files == before)
        #expect(Set(ring.keyIDs).isSuperset(of: keysBefore), "every key that existed is still held")
        #expect(try journal.replay().records.map { text($0.bytes) } == ["record-1", "record-3"])

        // Once the loss is accepted it goes through, and is counted.
        let events = RecordingInstrumentation()
        try withAmbient({ $0.instrumentation = events }) {
            try journal.compact(rotatingKey: true, unreadable: .discard, Self.fold)
        }
        #expect(Self.items(try journal.replay()) == ["record-1", "record-3"])
        #expect(try journal.replay().isComplete)
        #expect(events.events(named: "sealed.journal_compacted").first?["discarded"].map(\.description) == "1")
    }

    /// A custody that fails the stores whose number (from 1) it is told to.
    final class FlakyCustody: KeyCustody {
        let base = InMemoryKeyCustody()
        let failing: Set<Int>
        let stores = SendableBox(0)
        init(failing: Set<Int>) { self.failing = failing }
        func load(name: String) throws(CustodyError) -> [UInt8]? { try base.load(name: name) }
        func store(_ bytes: [UInt8], name: String) throws(CustodyError) {
            let number = stores.mutateReturning { $0 += 1; return $0 }
            if failing.contains(number) { throw .unavailable(.locked) }
            try base.store(bytes, name: name)
        }
        func delete(name: String) throws(CustodyError) { try base.delete(name: name) }
    }

    @Test(.failureMode("design/24", "the old keys cannot be retired after a compaction"))
    func aCompactionThatCouldNotRetireIsSaidToBeDoneButNotShredded() throws {
        let disk = try Self.disk()
        let custody = FlakyCustody(failing: [3])     // 1: create, 2: rotate, 3: retire
        let ring = try Keyring.open(name: "r", custody: custody, ifMissing: .create).keyring
        let journal = try Self.open(disk, ring)
        try journal.append(bytes("SECRET"))
        let oldKey = try ring.current
        let events = RecordingInstrumentation()
        do throws(SealedStoreError) {
            try withAmbient({ $0.instrumentation = events }) { () throws(SealedStoreError) in try journal.compact(rotatingKey: true, Self.fold) }
        } catch {
            if case .compactedButNotShredded(.custody(.unavailable(.locked))) = error {} else { Issue.record("\(error)") }
        }
        #expect(events.events(named: "sealed.shred_incomplete").count == 1)
        // The compaction itself stands: the snapshot is durable under the new key.
        #expect(Self.items(try journal.replay()) == ["SECRET"] && journal.byteCount == 0)
        // The old key is still held, which is exactly what the error says.
        #expect(ring.key(id: oldKey.id) != nil)
        // And the next compaction with rotation finishes the job.
        try journal.compact(rotatingKey: true, Self.fold)
        #expect(ring.keyIDs.count == 1 && ring.key(id: oldKey.id) == nil)
        #expect(Self.items(try journal.replay()) == ["SECRET"])
    }

    @Test func aRotationThatCannotBeStoredCompactsNothing() throws {
        let disk = try Self.disk()
        let custody = FlakyCustody(failing: [2])
        let ring = try Keyring.open(name: "r", custody: custody, ifMissing: .create).keyring
        let journal = try Self.open(disk, ring)
        try journal.append(bytes("a"))
        let before = disk.files
        do throws(SealedStoreError) { try journal.compact(rotatingKey: true, Self.fold) } catch {
            if case .keyring(.custody(.unavailable(.locked))) = error {} else { Issue.record("\(error)") }
        }
        #expect(disk.files == before)
        #expect(ring.keyIDs.count == 1)
    }

    // MARK: Crash consistency of a compaction with rotation

    @Test(.failureMode("design/24", "the process dies at any step of a compaction that rotates the key"))
    func aCrashAtAnyStepOfARotatingCompactionLeavesEverythingReadable() throws {
        let history = ["r1", "r2", "r3", "r4"]
        let initial = InMemoryKeyCustody()
        let first = try Keyring.open(name: "r", custody: initial, ifMissing: .create).keyring
        let ringBytes = SendableBox<[[UInt8]]>([try #require(initial.contents(of: "r"))])    // the ring after 0, 1, 2 … stores

        let report = try exploreCrashes(
            "SealedJournal.compact(rotatingKey:)",
            setup: { disk in
                try disk.createDirectory("/d")
                let journal = try Self.open(disk, first)
                for item in history { try journal.append(bytes(item)) }
                try journal.close()
            },
            operation: { disk in
                let custody = RecordingCustody(base: initial, disk: disk, ringBytes: ringBytes)
                let ring = try Keyring.open(name: "r", custody: custody, ifMissing: .fail).keyring
                let journal = try Self.open(disk, ring)
                try journal.compact(rotatingKey: true, Self.fold)
                disk.checkpoint("returned")
                try journal.close()
            },
            check: { disk, crash in
                // The custody as it was at this instant: the last ring stored by now.
                let stored = crash.count(prefix: "ring:")
                let custody = InMemoryKeyCustody(["r": ringBytes.value[stored]])
                let ring = try Keyring.open(name: "r", custody: custody, ifMissing: .fail).keyring
                let journal = try Self.open(disk, ring)
                let replay = try journal.replay()
                guard replay.isComplete else { return "something could not be opened: \(replay.failures) (ring after \(stored) stores)" }
                guard Self.items(replay) == history else { return "found \(Self.items(replay)), not \(history)" }
                if stored == 2 {
                    guard ring.keyIDs.count == 1 else { return "the old key was retired, but the ring holds \(ring.keyIDs.count) keys" }
                }
                if crash.reached("returned"), ring.keyIDs.count != 1 { return "the compaction returned, but the old key is still held" }
                // And it goes on.
                _ = try journal.append(bytes("after"))
                guard Self.items(try journal.replay()) == history + ["after"] else { return "an append after recovery was lost" }
                return nil
            }
        )
        print(report)
        #expect(report.violations.isEmpty, "\(report.violations.prefix(3).joined(separator: "\n"))")
        #expect(report.crashPoints >= 8)
    }

    /// Stores each ring it is given into a list as well, and tells the disk.
    final class RecordingCustody: KeyCustody {
        let base: InMemoryKeyCustody
        let disk: SimulatedFileSystem
        let ringBytes: SendableBox<[[UInt8]]>
        let count = SendableBox(0)
        init(base: InMemoryKeyCustody, disk: SimulatedFileSystem, ringBytes: SendableBox<[[UInt8]]>) {
            self.base = base; self.disk = disk; self.ringBytes = ringBytes
        }
        func load(name: String) throws(CustodyError) -> [UInt8]? { try base.load(name: name) }
        func store(_ bytes: [UInt8], name: String) throws(CustodyError) {
            try base.store(bytes, name: name)
            ringBytes.mutate { $0.append(bytes) }
            let number = count.mutateReturning { $0 += 1; return $0 }
            disk.checkpoint("ring:\(number)")
        }
        func delete(name: String) throws(CustodyError) { try base.delete(name: name) }
    }

    // MARK: Concurrency

    @Test(.failureMode("design/24", "records are appended while a compaction rotates the key"))
    func appendsRacingRotatingCompactionsAreNeverSealedUnderARetiredKey() throws {
        let dir = try TempDirectory()
        let (ring, _) = try makeRing()
        let journal = try SealedJournal.open(at: dir.file("log"), context: Self.context, keyring: ring)
        let problems = SendableBox<[String]>([])
        let threads = 6, perThread = 60
        DispatchQueue.concurrentPerform(iterations: threads + 1) { worker in
            if worker == threads {
                for _ in 0..<12 {
                    do { try journal.compact(rotatingKey: true, Self.fold) } catch { problems.mutate { $0.append("compact: \(error)") } }
                }
                return
            }
            for index in 0..<perThread {
                do { try journal.append(bytes("t\(worker)-\(index)")) } catch { problems.mutate { $0.append("append: \(error)") } }
            }
        }
        #expect(problems.value.isEmpty, "\(problems.value.prefix(3))")
        let replay = try journal.replay()
        #expect(replay.isComplete, "nothing was sealed under a key that was then retired: \(replay.failures.prefix(3))")
        let found = Self.items(replay)
        #expect(found.count == threads * perThread)
        #expect(Set(found).count == threads * perThread, "each exactly once")
        for worker in 0..<threads {
            let mine = found.filter { $0.hasPrefix("t\(worker)-") }.compactMap { Int($0.dropFirst("t\(worker)-".count)) }
            #expect(mine == Array(0..<perThread), "worker \(worker)'s records are in order")
        }
        #expect(ring.keyIDs.count <= 2, "old keys are retired as the compactions go: \(ring.keyIDs.count)")
    }

    // MARK: A second process

    @Test(.failureMode("design/24", "a second process reads a sealed journal while another writes it"))
    func aReaderOpensWhatTheWriterAppendedAndNeedsAReloadAfterARotation() throws {
        let disk = try Self.disk()
        let custody = InMemoryKeyCustody()
        let writerRing = try Keyring.open(name: "r", custody: custody, ifMissing: .create).keyring
        let readerRing = try Keyring.open(name: "r", custody: custody, ifMissing: .fail).keyring
        let writer = try Self.open(disk, writerRing)
        try writer.append(batch: [bytes("one"), bytes("two")])
        let before = disk.files

        func read() throws -> SealedJournal.Replay {
            try SealedJournal.readOnlyReplay(at: Self.path, context: Self.context, keyring: readerRing, fileSystem: disk)
        }
        #expect(Self.items(try read()) == ["one", "two"])
        #expect(disk.files == before, "a reader changes nothing")

        try writer.compact(rotatingKey: true, Self.fold)
        try writer.append(bytes("three"))
        let stale = try read()
        #expect(!stale.isComplete, "the reader's keyring does not know the new key")
        #expect(stale.failures.allSatisfy { if case .unknownKey = $0.error { true } else { false } })
        try readerRing.reload()
        let fresh = try read()
        #expect(fresh.isComplete && Self.items(fresh) == ["one", "two", "three"])
        #expect(try writer.replay().records.map { text($0.bytes) } == ["three"])
    }
}
#endif
