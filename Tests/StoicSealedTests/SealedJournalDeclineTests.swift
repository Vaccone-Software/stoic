#if STOIC_CRYPTO
import Foundation
import Stoic
@testable import StoicSealed
@testable import StoicStore
import StoicTesting
import Testing

/// A compaction that the caller's fold declines, or that is refused or fails
/// before it has a snapshot, changes nothing: no file, and no key.
@Suite("SealedJournal compaction declined")
struct SealedJournalDeclineTests {
    static let path = SealedJournalTests.path

    /// A journal holding three records, and its ring in a custody that counts calls.
    static func fixture() throws -> (disk: SimulatedFileSystem, ring: Keyring, custody: InMemoryKeyCustody, journal: SealedJournal) {
        let disk = try SealedJournalTests.disk()
        let (ring, custody) = try makeRing()
        let journal = try SealedJournalTests.open(disk, ring)
        for index in 1...3 { try journal.append(bytes("record-\(index)")) }
        return (disk, ring, custody, journal)
    }

    static func stores(_ custody: InMemoryKeyCustody) -> Int { custody.calls.filter { $0.operation == .store }.count }

    @Test(.failureMode("design/24", "a compaction's fold declines"), arguments: [false, true])
    func aFoldThatDeclinesChangesNothingAndMakesNoKey(rotatingKey: Bool) throws {
        let (disk, ring, custody, journal) = try Self.fixture()
        let files = disk.files
        let keys = ring.keyIDs
        let storesBefore = Self.stores(custody)
        let events = RecordingInstrumentation()
        let saw = SendableBox<[Int]>([])

        let compacted = try withAmbient({ $0.instrumentation = events }) { () throws(SealedStoreError) in
            try journal.compact(rotatingKey: rotatingKey) { replay in
                saw.mutate { $0.append(replay.records.count) }
                return nil
            }
        }

        #expect(compacted == false)
        #expect(saw.value == [3], "the fold saw the whole state, once")
        #expect(disk.files == files, "no snapshot, no truncation, nothing written")
        #expect(ring.keyIDs == keys, "no key was rotated, none retired")
        #expect(Self.stores(custody) == storesBefore, "the custody was not written")
        #expect(events.events(named: "sealed.journal_compacted").isEmpty && events.events(named: "sealed.keyring_created").isEmpty)
        #expect(events.events(named: "sealed.key_rotated").isEmpty)
        // The journal is as it was, and still takes appends and a real compaction.
        #expect(try SealedJournalTests.items(journal.replay()) == ["record-1", "record-2", "record-3"])
        #expect(try journal.append(bytes("record-4")) == 4)
        #expect(try journal.compact(rotatingKey: rotatingKey, SealedJournalTests.fold) == true)
        #expect(try SealedJournalTests.items(journal.replay()) == ["record-1", "record-2", "record-3", "record-4"])
        if rotatingKey {
            #expect(ring.keyIDs.count == 1 && Set(ring.keyIDs).isDisjoint(with: keys), "a compaction that went through did rotate")
        } else {
            #expect(ring.keyIDs == keys)
        }
    }

    @Test func aFoldIsGivenTheStateBeforeAnyKeyIsMade() throws {
        let (_, ring, custody, journal) = try Self.fixture()
        let storesBefore = Self.stores(custody)
        let during = SendableBox<(keys: Int, stores: Int)?>(nil)
        try journal.compact(rotatingKey: true) { replay in
            during.mutate { $0 = (ring.keyIDs.count, Self.stores(custody)) }
            return SealedJournalTests.fold(replay)
        }
        #expect(during.value?.keys == 1 && during.value?.stores == storesBefore, "rotation comes after the fold, not before it")
        #expect(ring.keyIDs.count == 1 && Self.stores(custody) == storesBefore + 2, "then one store to rotate and one to retire")
    }

    @Test func aRefusedCompactionRotatesNothing() throws {
        let (disk, ring, custody, journal) = try Self.fixture()
        try journal.close()
        var stored = try SealedJournalTests.storedRecords(disk)
        stored[1].bytes[45] ^= 1
        try SealedJournalTests.rewriteLog(disk, stored)
        let reopened = try SealedJournalTests.open(disk, ring)
        let files = disk.files
        let keys = ring.keyIDs
        let storesBefore = Self.stores(custody)
        let folded = SendableBox(0)

        do throws(SealedStoreError) {
            try reopened.compact(rotatingKey: true) { _ in folded.mutate { $0 += 1 }; return bytes("x") }
            Issue.record("a compaction over an unreadable record must refuse")
        } catch {
            if case .unreadable(let count) = error { #expect(count == 1) } else { Issue.record("\(error)") }
        }
        #expect(folded.value == 0, "the fold is not asked to summarise what could not be read")
        #expect(disk.files == files)
        #expect(ring.keyIDs == keys, "a refusal leaves no extra key")
        #expect(Self.stores(custody) == storesBefore)
    }

    @Test func aKeyringThatCannotRotateFailsBeforeAnythingIsWritten() throws {
        let (disk, ring, custody, journal) = try Self.fixture()
        let files = disk.files
        custody.failNext(with: .unavailable(.locked), on: .store)
        do throws(SealedStoreError) {
            try journal.compact(rotatingKey: true, SealedJournalTests.fold)
            Issue.record("the rotation failed, so the compaction must")
        } catch {
            if case .keyring(.custody(.unavailable(.locked))) = error {} else { Issue.record("\(error)") }
        }
        #expect(disk.files == files && ring.keyIDs.count == 1)
        #expect(try SealedJournalTests.items(journal.replay()) == ["record-1", "record-2", "record-3"])
    }

    @Test func aSnapshotThatCannotBeWrittenLeavesTheLogAndOnlyAnUnusedKey() throws {
        let (disk, ring, _, journal) = try Self.fixture()
        let keys = ring.keyIDs
        disk.inject(ENOSPC, on: .write)
        do throws(SealedStoreError) {
            try journal.compact(rotatingKey: true, SealedJournalTests.fold)
            Issue.record("the snapshot could not be written")
        } catch {
            if case .store(let store) = error { #expect(store.kind == .diskFull) } else { Issue.record("\(error)") }
        }
        // The old keys are still held (nothing was retired), and what the
        // rotation made sealed nothing: the documented cost of a failure after it.
        #expect(Set(ring.keyIDs).isSuperset(of: keys) && ring.keyIDs.count == keys.count + 1)
        #expect(try SealedJournalTests.items(journal.replay()) == ["record-1", "record-2", "record-3"])
        // The next compaction with rotation shreds what both rotations left.
        #expect(try journal.compact(rotatingKey: true, SealedJournalTests.fold))
        #expect(ring.keyIDs.count == 1 && Set(ring.keyIDs).isDisjoint(with: keys))
    }

    @Test func aSnapshotCompactionStillReplacesTheLog() throws {
        let (_, _, _, journal) = try Self.fixture()
        try journal.compact(snapshot: bytes("folded"))
        let replay = try journal.replay()
        #expect(replay.snapshot.map { text($0.bytes) } == "folded" && replay.records.isEmpty)
    }
}
#endif
