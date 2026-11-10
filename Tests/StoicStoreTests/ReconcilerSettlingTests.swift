import Stoic
@testable import StoicStore
import StoicTesting
import Testing

/// `Reconciler.settling(_:)` over a device's store (design/27, design/30).
@Suite("Reconciler settling a device's store")
struct JournaledSettlingTests {
    @Test(.failureMode("design/30", "settleDue settles several records"))
    func severalDueRecordsAreSettledInOneBatchAndCountedAsCorrected() async throws {
        let disk = try lifecycleDisk()
        let clock = TestClock()
        try await withTestAmbient(clock: clock) {
            let notices = try await NoticeStore.openTest(disk)
            for id in ["a", "b", "c"] {
                _ = try await notices.insert(.make(.draft, by: "ana", key: "notice-\(id)"), as: id)
                try await notices.apply(.send, to: id, by: "ana", because: "the coordinator sent it")
            }
            let reconciler = Reconciler.settling(notices)
            await clock.advance(by: .seconds(61))
            disk.settle()
            let report = try await reconciler.pass()
            #expect(report.applied == 3)
            #expect(report.differences == 3)
            for id in ["a", "b", "c"] { #expect(try await notices.read(id)?.state == .lapsed) }
            let journalSyncs = disk.operations.filter {
                if case .fullSync(let path) = $0 { path.hasPrefix("/d/notices") && !path.contains("effects") } else { false }
            }
            #expect(journalSyncs.count == 1, "one batch append: \(disk.operations)")
            #expect(reconciler.status.phase == .converged)
            try await notices.close()
        }
    }

    @Test func itWakesAtTheStoresNextDue() async throws {
        let disk = try lifecycleDisk()
        _ = try await simulate(seed: 0, faults: .none, schedule: .uniform) { context in
            let notices = try await NoticeStore.openTest(disk)
            _ = try await notices.insert(.make(.draft, by: "ana", at: Moment.now, key: "notice-a"), as: "a")
            try await notices.apply(.send, to: "a", by: "ana", because: "sent")
            let reconciler = Reconciler.settling(notices)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await reconciler.run() }
                while try await notices.read("a")?.state != .lapsed { try await Ambient.sleep(for: .seconds(1)) }
                group.cancelAll()
            }
            #expect(context.clock.now.offset <= .seconds(61), "a minute after it was sent, not at the fifteen-minute schedule")
            try await notices.close()
        }
    }

    @Test func aRecordStillDueAfterSettleDueIsRefused() async throws {
        let disk = try lifecycleDisk()
        let clock = TestClock()
        try await withTestAmbient(clock: clock) {
            // A record written by a newer definition: this build cannot settle it.
            let newer = try await JournaledLifecycleStore<NoticeV2, String>.openTest(disk)
            _ = try await newer.insert(.make(.draft, by: "ana", key: "notice-new"), as: "new")
            try await newer.apply(.send, to: "new", by: "ana", because: "sent by the newer build")
            try await newer.close()
            let notices = try await NoticeStore.openTest(disk)
            let reconciler = Reconciler.settling(notices)
            await clock.advance(by: .seconds(61))
            let report = try await reconciler.pass()
            #expect(report.applied == 0)
            #expect(reconciler.status.stuck.map(\.key) == ["new"])
            #expect(reconciler.status.stuck.first?.reason == .refused("its timeout does not move it"))
            try await notices.close()
        }
    }

    /// design/30's ideal scenario, the device's half: Lodestar's release
    /// records, kept by `Reconciler.settling` while the app runs.
    @Test func aStalledDownloadIsOfferedAgainWhenItsTimeoutFallsDue() async throws {
        let disk = try lifecycleDisk()
        _ = try await simulate(seed: 0, faults: .none, schedule: .uniform) { context in
            typealias Releases = JournaledLifecycleStore<ReleaseOnThisMac, String>
            let releases = try await Releases.open(
                at: "/d/releases", fileSystem: disk, delivery: DeliveryPolicy(schedule: .immediate.attempts(1)))
            _ = try await releases.insert(.new(in: .offered, by: .updater, because: "the feed offered 0.56"), as: "0.56")
            try await releases.apply(.download, to: "0.56", by: .updater, because: "the person chose to update")
            let releasesDue = Reconciler.settling(releases)
            let upkeep = Supervisor(label: "lodestar.upkeep") {
                Child("releases-due") { _ in try await releasesDue.run() }
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await upkeep.run() }
                // The written state, not a reading, which projects a due timeout by itself.
                while try await releases.load("0.56")?.written.state != .offered { try await Ambient.sleep(for: .seconds(30)) }
                #expect(context.clock.now.offset <= .seconds(30 * 60 + 30), "at the stall's due moment, not a schedule later")
                let history = try await releases.history(of: "0.56")
                #expect(history.last?.by == .timeout)
                #expect(history.last?.event == .stall)
                group.cancelAll()
            }
            try await releases.close()
        }
    }
}
