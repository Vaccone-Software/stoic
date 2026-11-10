import Foundation
import Stoic
@testable import StoicStore
import StoicTesting
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// design/27 on a device: `JournaledLifecycleStore` on a simulated disk.
@Suite("Lifecycle store on a device")
struct JournaledLifecycleStoreTests {
    /// Inserts a draft notice under `id` and sends it at the store's now.
    func sentNotice(_ store: NoticeStore, _ id: String = "n1", key: String = "notice-key-0123456789abcd") async throws {
        #expect(try await store.insert(.make(.draft, by: "p", key: key), as: id))
        try await store.apply(.send, to: id, by: "p", because: "sent by a test")
    }

    func delivered(_ store: NoticeStore) async throws -> [String] {
        let seen = SendableBox<[String]>([])
        _ = try await withTestAmbient(clock: ImmediateClock()) {
            try await store.deliverEffects { delivery in
                seen.mutate { $0.append("\(delivery.id) \(delivery.effect)") }
                return .delivered
            }
        }
        return seen.value
    }

    @Test func aCommitSurvivesARelaunchWithItsHistoryAndEffects() async throws {
        let disk = try lifecycleDisk()
        try await withTestAmbient(clock: TestClock()) {
            var store = try await NoticeStore.openTest(disk)
            try await sentNotice(store)
            try await store.close()
            store = try await NoticeStore.openTest(disk)
            let record = try #require(try await store.load("n1"))
            #expect(record.written.state == .sent && record.revision == 2)
            let history = try await store.history(of: "n1")
            try LifecycleHistory.verify(history, of: record)
            #expect(try await delivered(store) == ["n1 mail(\"sent\")"])
            #expect(await store.records().map(\.id) == ["n1"])
            try await store.close()
        }
    }

    // MARK: Undecodable records

    @Test(.failureMode("design/27", "a stored record holds a state this build does not know"))
    func aRecordANewerBuildWroteIsKeptIntact() async throws {
        let disk = try lifecycleDisk()
        let events = RecordingInstrumentation()
        try await withTestAmbient(clock: TestClock(), events: events) {
            // The newer build archives one notice and leaves another.
            let newer = try await JournaledLifecycleStore<NoticeV2, String>.openTest(disk, threshold: 1)
            _ = try await newer.insert(.make(.done, by: "p", key: "archived-key-0123456789ab"), as: "old")
            try await newer.apply(.finish, to: "old", by: "p", because: "archived")
            _ = try await newer.insert(.make(.draft, by: "p", key: "kept-key-0123456789abcdef"), as: "kept")
            try await newer.close()
            let before = disk.files

            // The older build opens the store, works on the other record, compacts.
            let older = try await NoticeStore.openTest(disk, threshold: 1)
            #expect(older.openReport.undecodable == ["old"])
            await #expect(throws: StoreError.self) { try await older.load("old") }
            await #expect(throws: StoreError.self) { try await older.history(of: "old") }
            #expect(try await older.insert(.make(.draft, by: "p", key: "other-key-0123456789abcd"), as: "old") == false)
            #expect(try await older.insert(.make(.draft, by: "p", key: "mine-key-0123456789abcdef"), as: "mine"))
            try await older.apply(.send, to: "mine", by: "p", because: "the older build sends")
            #expect(await older.records().map(\.id) == ["kept", "mine"])
            #expect(try await older.purge(finishedBefore: wallStart + .seconds(1_000_000)) == 0, "never purged unread")
            try await older.close()
            #expect(disk.files != before)

            // Back on the newer build: the record is as it wrote it.
            let again = try await JournaledLifecycleStore<NoticeV2, String>.openTest(disk)
            let record = try #require(try await again.load("old"))
            #expect(record.written.state == .archived && record.version == 2)
            try LifecycleHistory.verify(try await again.history(of: "old"), of: record)
            #expect(try await again.load("mine")?.written.state == .sent)
            try await again.close()
        }
        let undecodable = try #require(events.events(named: "lifecycle.undecodable").first)
        #expect(undecodable.level == .error)
    }

    // MARK: Hand-off

    @Test(.failureMode("design/27", "an effect's enqueue fails after the commit"))
    func aFailedHandOffLeavesTheCommitAndIsRetried() async throws {
        let disk = try lifecycleDisk()
        let events = RecordingInstrumentation()
        try await withTestAmbient(clock: TestClock(), events: events) {
            let store = try await NoticeStore.openTest(disk)
            #expect(try await store.insert(.make(.draft, by: "p", key: "notice-key-0123456789abcd"), as: "n1"))
            // The journal's write succeeds; the outbox's, the next one, fails.
            disk.inject(ENOSPC, on: .write, skipping: 1)
            let record = try await store.apply(.send, to: "n1", by: "p", because: "sent")
            #expect(record.written.state == .sent, "the commit stands")
            #expect(try await store.load("n1")?.revision == 2)
            // The next delivery hands it over first.
            #expect(try await delivered(store) == ["n1 mail(\"sent\")"])
            try await store.close()
        }
        #expect(events.events(named: "lifecycle.handoff_deferred").map(\.level) == [.warning])
    }

    @Test(.failureMode("design/27", "the process dies after the commit and before its effects reach the outbox"))
    func recoveryHandsOverWhatTheLastRunDidNot() async throws {
        var disk = try lifecycleDisk()
        let events = RecordingInstrumentation()
        try await withTestAmbient(clock: TestClock(), events: events) {
            let store = try await NoticeStore.openTest(disk)
            #expect(try await store.insert(.make(.draft, by: "p", key: "notice-key-0123456789abcd"), as: "n1"))
            disk.inject(EIO, on: .write, skipping: 1, count: 10)
            try await store.apply(.send, to: "n1", by: "p", because: "sent")
            disk = afterCrash(disk)
            disk.clearFaults()
            let reopened = try await NoticeStore.openTest(disk)
            #expect(reopened.openReport.handOffsResumed == 1)
            #expect(try await delivered(reopened) == ["n1 mail(\"sent\")"])
            try await reopened.close()
        }
        #expect(events.events(named: "lifecycle.handoff_resumed").first?["commits"]?.description == "1")
    }

    @Test(.failureMode("design/27", "the process dies after an effect was delivered and before the hand-off mark was durable"))
    func aDeliveredEffectHandedOverAgainIsNotSent() async throws {
        var disk = try lifecycleDisk()
        try await withTestAmbient(clock: TestClock()) {
            let store = try await NoticeStore.openTest(disk)
            try await sentNotice(store)
            #expect(try await delivered(store) == ["n1 mail(\"sent\")"])
            // No append since: the journal's durable mark is still before the commit.
            disk = afterCrash(disk)
            let reopened = try await NoticeStore.openTest(disk)
            #expect(reopened.openReport.handOffsResumed == 1, "handed over again")
            #expect(try await delivered(reopened).isEmpty, "the outbox remembers its key: nothing is sent")
            try await reopened.close()
        }
    }

    /// The bound, made small: the outbox remembers two keys. Three effects
    /// wait in the outbox; a fourth commit's effect is delivered ahead of them
    /// (a run that continues past failures); the three then settle, and push
    /// it out of the window; the process dies before any append carries the
    /// hand-off mark past its commit. Recovery hands it over again, and it is
    /// delivered again, under its key.
    @Test(.failureMode("design/27", "a hand-off keeps failing while a backlog of more than 4 096 entries settles out of order"))
    func pastTheBoundAnEffectMayBeDeliveredAgainUnderItsKey() async throws {
        var disk = try lifecycleDisk()
        try await withTestAmbient(clock: ImmediateClock()) {
            let policy = DeliveryPolicy(schedule: .immediate.attempts(1), onFailure: .continueWithNext)
            let store = try await NoticeStore.open(at: "/d/notices", fileSystem: disk, delivery: policy, rememberSettled: 2)
            for index in 1...3 { try await sentNotice(store, "n\(index)", key: "notice-key-\(index)-0123456789ab") }
            try await sentNotice(store, "late", key: "notice-key-late-0123456789")
            struct Busy: Error, Retryable { var retryDecision: RetryDecision { .stop } }
            _ = try await store.deliverEffects { delivery in
                guard delivery.id == "late" else { throw Busy() }
                return .delivered
            }
            let backlog = try await store.deliverEffects { _ in .delivered }
            #expect(backlog.delivered.count == 3, "the backlog settles after it")
            disk = afterCrash(disk)
            let reopened = try await NoticeStore.open(at: "/d/notices", fileSystem: disk, delivery: policy, rememberSettled: 2)
            #expect(reopened.openReport.handOffsResumed == 1)
            #expect(try await delivered(reopened) == ["late mail(\"sent\")"], "forgotten, and delivered again under the same key")
            try await reopened.close()
        }
    }

    // MARK: Failures of the journal

    @Test(.failureMode("design/27", "the journal append of a commit fails"))
    func aFailedAppendChangesNothing() async throws {
        let disk = try lifecycleDisk()
        try await withTestAmbient(clock: TestClock()) {
            let store = try await NoticeStore.openTest(disk)
            #expect(try await store.insert(.make(.draft, by: "p", key: "notice-key-0123456789abcd"), as: "n1"))
            disk.inject(ENOSPC, on: .write)
            await #expect(throws: (any Error).self) { try await store.apply(.send, to: "n1", by: "p", because: "sent") }
            #expect(try await store.load("n1")?.revision == 1)
            #expect(try await store.history(of: "n1").isEmpty)
            #expect(try await delivered(store).isEmpty, "nothing is enqueued")
            // It works afterwards.
            try await store.apply(.send, to: "n1", by: "p", because: "sent")
            #expect(try await delivered(store) == ["n1 mail(\"sent\")"])
            try await store.close()
        }
    }

    @Test(.failureMode("design/27", "the journal's sync fails during a commit"))
    func aFailedSyncIsThrownAndPoisonsTheJournal() async throws {
        let disk = try lifecycleDisk()
        try await withTestAmbient(clock: TestClock()) {
            let store = try await NoticeStore.openTest(disk)
            #expect(try await store.insert(.make(.draft, by: "p", key: "notice-key-0123456789abcd"), as: "n1"))
            disk.inject(EIO, on: .fullSync)
            await #expect(throws: (any Error).self) { try await store.apply(.send, to: "n1", by: "p", because: "sent") }
            #expect(try await store.load("n1")?.revision == 1, "nothing committed")
            do throws(LifecycleUpdateError<Notice, StoreError>) {
                try await store.apply(.send, to: "n1", by: "p", because: "sent again")
                Issue.record("a poisoned journal appended")
            } catch .storage(let error) {
                #expect(error.kind == .poisoned)
            }
            try? await store.close()
            let reopened = try await NoticeStore.openTest(disk)
            #expect(try await reopened.load("n1")?.revision == 1)
            try await reopened.close()
        }
    }

    @Test(.failureMode("design/27", "a change made from one record is committed to another"))
    func aChangeFromAnotherRecordIsRefusedOnADevice() async throws {
        let disk = try lifecycleDisk()
        try await withTestAmbient(clock: TestClock()) {
            let store = try await NoticeStore.openTest(disk)
            let first = Notice.Record.make(.draft, by: "p", key: "first-key-0123456789abcdef")
            #expect(try await store.insert(first, as: "a"))
            #expect(try await store.insert(.make(.draft, by: "p", key: "other-key-0123456789abcdef"), as: "b"))
            let operations = disk.operationCount
            let change = try first.applying(.send, by: "p", because: "sent", at: wallStart)
            do throws(StoreError) {
                _ = try await store.commit(change, to: "b")
                Issue.record("a foreign change committed")
            } catch {
                #expect(error.kind == .invalidArgument)
            }
            #expect(disk.operationCount == operations, "nothing written")
            try await store.close()
        }
    }

    // MARK: Settling, purging, compacting

    @Test(.failureMode("design/27", "`settleDue` finds several records due"))
    func settleDueCommitsEveryDueRecordInOneBatch() async throws {
        let disk = try lifecycleDisk()
        let clock = TestClock()
        try await withTestAmbient(clock: clock) {
            let store = try await NoticeStore.openTest(disk)
            for index in 1...3 { try await sentNotice(store, "n\(index)", key: "notice-key-\(index)-0123456789ab") }
            #expect(try await store.insert(.make(.draft, by: "p", key: "draft-key-0123456789abcd"), as: "d"))
            #expect(await store.nextDue == wallStart + .seconds(60))
            _ = try await delivered(store)
            clock.jumpWallClock(by: .seconds(61))
            let before = disk.operationCount
            #expect(try await store.settleDue() == 3)
            // One append: the three commits share one write and one sync of the journal.
            let journal = disk.operations.dropFirst(before).filter { operation in
                switch operation {
                case .write(let path, _, _), .fullSync(let path): path == "/d/notices"
                default: false
                }
            }
            #expect(journal.count == 2, "\(journal)")
            for index in 1...3 { #expect(try await store.load("n\(index)")?.written.state == .lapsed) }
            #expect(await store.nextDue == nil)
            #expect(Set(try await delivered(store)) == Set((1...3).map { "n\($0) mail(\"lapsed\")" }))
            #expect(try await store.settleDue() == 0, "nothing more is due")
            try await store.close()
        }
    }

    @Test(.failureMode("design/27", "a final record is purged"))
    func aFinalRecordAndItsHistoryArePurgedTogether() async throws {
        let disk = try lifecycleDisk()
        let events = RecordingInstrumentation()
        let clock = TestClock()
        try await withTestAmbient(clock: clock, events: events) {
            var store = try await NoticeStore.openTest(disk)
            try await sentNotice(store)
            try await store.apply(.finish, to: "n1", by: "p", because: "done")
            try await sentNotice(store, "n2", key: "notice-key-2-0123456789ab")
            clock.jumpWallClock(by: .seconds(10))
            #expect(try await store.purge(finishedBefore: Moment.now) == 1, "the sent notice is not final")
            #expect(try await store.load("n1") == nil)
            let gone = try await store.history(of: "n1")
            #expect(gone.isEmpty)
            #expect(try await store.load("n2") != nil)
            try await store.close()
            store = try await NoticeStore.openTest(disk)
            #expect(try await store.load("n1") == nil)
            #expect(await store.records().map(\.id) == ["n2"])
            try await store.close()
        }
        #expect(events.events(named: "lifecycle.purged").first?["count"]?.description == "1")
    }

    @Test func compactionFoldsHeadsAndHistoriesAndWaitsForTheHandOff() async throws {
        let disk = try lifecycleDisk()
        try await withTestAmbient(clock: TestClock()) {
            var store = try await NoticeStore.openTest(disk, threshold: 1)
            try await sentNotice(store)
            try await store.apply(.finish, to: "n1", by: "p", because: "done")
            try await store.close()
            let journal = try Journal.open(at: "/d/notices", fileSystem: disk)
            let replay = try journal.replay()
            try journal.close()
            #expect(replay.snapshot != nil, "compacted once the hand-off was done")
            store = try await NoticeStore.openTest(disk)
            let record = try #require(try await store.load("n1"))
            try LifecycleHistory.verify(try await store.history(of: "n1"), of: record)
            #expect(record.written.state == .done && record.sequence == 2)
            try await store.close()
        }
    }

    @Test func aFailedCompactionLosesNothingAndIsReported() async throws {
        let disk = try lifecycleDisk()
        let events = RecordingInstrumentation()
        try await withTestAmbient(clock: TestClock(), events: events) {
            var store = try await NoticeStore.openTest(disk, threshold: 1)
            // The snapshot is written to a temporary file and renamed into place.
            disk.inject(EIO, on: .rename, count: 100)
            #expect(try await store.insert(.make(.draft, by: "p", key: "notice-key-0123456789abcd"), as: "n1"))
            disk.clearFaults()
            #expect(try await store.load("n1") != nil)
            try await store.close()
            store = try await NoticeStore.openTest(disk)
            #expect(try await store.load("n1")?.written.state == .draft, "the log is whole")
            try await store.close()
        }
        let failed = try #require(events.events(named: "lifecycle.maintenance_failed").first)
        #expect(failed.level == .warning && failed["operation"]?.description == "compact")
    }

    // MARK: The device's clock belongs to its owner

    @Test(.failureMode("design/27", "a device's clock is set back while its store is open"))
    func aClockSetBackCannotUnexpireAStateThroughAnOpenStore() async throws {
        let disk = try lifecycleDisk()
        let clock = TestClock()
        let events = RecordingInstrumentation()
        try await withTestAmbient(clock: clock, events: events) {
            let store = try await NoticeStore.openTest(disk)
            try await sentNotice(store)
            clock.jumpWallClock(by: .seconds(120))
            #expect(try await store.read("n1")?.state == .lapsed)
            // The person sets the clock back an hour.
            clock.jumpWallClock(by: .seconds(-3_600))
            #expect(try await store.read("n1")?.state == .lapsed, "still lapsed: the store reads at its latest moment")
            #expect(await store.moment(for: .now) == wallStart + .seconds(120))
            let record = try await store.apply(.send, to: "n1", by: "p", because: "sent again")
            let history = try await store.history(of: "n1")
            #expect(history.map(\.event) == [.send, .lapse, .send])
            #expect(history.last?.at == wallStart + .seconds(120))
            #expect(record.written.since == wallStart + .seconds(120))
            try await store.close()
        }
        #expect(!events.events(named: "lifecycle.clock_behind").isEmpty)
        #expect(events.events(named: "lifecycle.clock_behind").allSatisfy { $0.level == .notice })
    }

    @Test(.failureMode("design/27", "a device's clock is set back across a relaunch after an append"))
    func theLatestMomentIsDurableWithEachAppendAndAtClose() async throws {
        var disk = try lifecycleDisk()
        let clock = TestClock()
        try await withTestAmbient(clock: clock) {
            var store = try await NoticeStore.openTest(disk)
            try await sentNotice(store)
            clock.jumpWallClock(by: .seconds(120))
            // A read moves the moment; close makes it durable.
            #expect(try await store.read("n1")?.state == .lapsed)
            try await store.close()
            clock.jumpWallClock(by: .seconds(-3_600))
            store = try await NoticeStore.openTest(disk)
            #expect(try await store.read("n1")?.state == .lapsed)
            // And an append makes it durable even without a close.
            clock.jumpWallClock(by: .seconds(3_600 + 300))
            #expect(try await store.insert(.make(.draft, by: "p", key: "draft-key-0123456789abcd"), as: "d"))
            try await store.apply(.send, to: "d", by: "p", because: "sent")
            disk = afterCrash(disk)
            clock.jumpWallClock(by: .seconds(-3_600))
            store = try await NoticeStore.openTest(disk)
            #expect(await store.moment(for: .now) == wallStart + .seconds(420))
            try await store.close()
        }
    }

    /// The stated limit: a read moves the moment in memory only, so a crash
    /// before any append loses it, and a clock set back across that relaunch
    /// can un-do a projected expiry. `settleDue` at launch makes it a fact.
    @Test(.failureMode("design/27", "a device's clock is set back across a relaunch with no append since the last read"))
    func aProjectedExpiryCanBeUndoneAcrossACrashUntilItIsSettled() async throws {
        var disk = try lifecycleDisk()
        let clock = TestClock()
        try await withTestAmbient(clock: clock) {
            var store = try await NoticeStore.openTest(disk)
            try await sentNotice(store)
            clock.jumpWallClock(by: .seconds(120))
            #expect(try await store.read("n1")?.state == .lapsed)
            disk = afterCrash(disk)   // no append, no close: the moment read is lost
            clock.jumpWallClock(by: .seconds(-90))
            store = try await NoticeStore.openTest(disk)
            #expect(try await store.read("n1")?.state == .sent, "the limit: projected, uncommitted, un-done")
            // Settled once, the expiry is a fact the clock cannot undo.
            clock.jumpWallClock(by: .seconds(90))
            #expect(try await store.settleDue() == 1)
            disk = afterCrash(disk)
            clock.jumpWallClock(by: .seconds(-90))
            store = try await NoticeStore.openTest(disk)
            #expect(try await store.read("n1")?.state == .lapsed)
            try await store.close()
        }
    }

    @Test func removeDeletesBothJournals() async throws {
        let disk = try lifecycleDisk()
        try await withTestAmbient(clock: TestClock()) {
            let store = try await NoticeStore.openTest(disk, threshold: 1)
            try await sentNotice(store)
            _ = try await delivered(store)
            try await store.close()
        }
        #expect(try NoticeStore.remove(at: "/d/notices", fileSystem: disk) >= 2)
        #expect(disk.files.keys.filter { $0.hasPrefix("/d/notices") }.isEmpty)
    }
}
