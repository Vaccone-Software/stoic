#if STOIC_CRYPTO
import Foundation
import Stoic
@testable import StoicSealed
@testable import StoicStore
import StoicTesting
import Testing

@Suite("SealedJournal.remove")
struct SealedJournalRemoveTests {
    static let path = SealedJournalTests.path

    @Test(.failureMode("design/24", "a sealed journal is removed"))
    func theJournalAndEverythingBesideItGoAndTheKeyringIsLeftAlone() throws {
        let disk = try SealedJournalTests.disk()
        let (ring, custody) = try makeRing()
        let journal = try SealedJournal.open(
            at: Self.path, context: SealedJournalTests.context, keyring: ring, fileSystem: disk, options: .init(crossProcessLock: true)
        )
        try journal.append(batch: [bytes("SECRET-1"), bytes("SECRET-2")])
        try journal.compact(rotatingKey: true, SealedJournalTests.fold)
        try journal.append(bytes("SECRET-3"))
        try journal.close()
        let keys = ring.keyIDs
        let custodyBefore = custody.contents(of: "test.keyring")
        let bystander = "/d/log.bak"
        let file = try disk.open(bystander, mode: .createExclusive)
        try disk.write(file, bytes("mine"), at: 0)
        try disk.fullSync(file)
        try disk.close(file)
        try disk.syncDirectory("/d")
        #expect(disk.files.keys.sorted() == [Self.path, bystander, Self.path + ".lock", Self.path + ".snapshot"])

        #expect(try SealedJournal.remove(at: Self.path, fileSystem: disk) == 3)

        #expect(disk.files.keys.sorted() == [bystander])
        #expect(ring.keyIDs == keys && custody.contents(of: "test.keyring") == custodyBefore, "removing files does not retire a key: that is the caller's decision")
        #expect(try SealedJournal.remove(at: Self.path, fileSystem: disk) == 0)
    }

    @Test func anOpenJournalIsBusyAsAStoreError() throws {
        let disk = try SealedJournalTests.disk()
        let (ring, _) = try makeRing()
        let journal = try SealedJournalTests.open(disk, ring)
        try journal.append(bytes("a"))
        let before = disk.files
        do throws(SealedStoreError) {
            try SealedJournal.remove(at: Self.path, fileSystem: disk)
            Issue.record("an open journal must not be removed")
        } catch {
            if case .store(let store) = error { #expect(store.kind == .busy) } else { Issue.record("\(error)") }
            #expect(error.retryDecision == .retry)
        }
        #expect(disk.files == before)
        try journal.close()
        #expect(try SealedJournal.remove(at: Self.path, fileSystem: disk) == 1)
    }

    @Test func removingTheFilesAndRetiringTheKeysIsWhatMakesACopyUnreadable() throws {
        // The advice in the documentation, run: a copy of the files made before
        // (a backup) opens only while the keys it was sealed under are held.
        let disk = try SealedJournalTests.disk()
        let (ring, _) = try makeRing()
        let journal = try SealedJournalTests.open(disk, ring)
        try journal.append(batch: [bytes("SECRET-1"), bytes("SECRET-2")])
        try journal.close()
        let backup = disk.fork()

        try SealedJournal.remove(at: Self.path, fileSystem: disk)
        let held = ring.keyIDs
        try ring.rotate()
        #expect(try ring.retire(ids: held) == held.count)

        // Files alone, with the ring as it was, would still open; with the ring as it is, nothing does.
        let restored = try SealedJournal.readOnlyReplay(at: Self.path, context: SealedJournalTests.context, keyring: ring, fileSystem: backup)
        #expect(restored.records.isEmpty)
        #expect(restored.failures.count == 2 && restored.failures.allSatisfy { if case .unknownKey = $0.error { true } else { false } })
    }
}
#endif
