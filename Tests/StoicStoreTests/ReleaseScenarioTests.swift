import Stoic
@testable import StoicStore
import StoicTesting
import Testing

/// design/27's second ideal scenario: Lodestar's updater keeps one record
/// per release on the Mac, across launches and builds.
@Suite("Lifecycles: a release on this Mac")
struct ReleaseScenarioTests {
    typealias Releases = JournaledLifecycleStore<ReleaseOnThisMac, String>
    static let path = "/d/releases"

    static func open(_ disk: SimulatedFileSystem) async throws -> Releases {
        try await Releases.open(at: path, fileSystem: disk, delivery: DeliveryPolicy(schedule: .immediate.attempts(1)))
    }

    /// What the person is told, collected.
    static func announce(_ releases: Releases) async throws -> [String] {
        let said = SendableBox<[String]>([])
        _ = try await withTestAmbient(clock: ImmediateClock()) {
            try await releases.deliverEffects { delivery in
                said.mutate { $0.append("\(delivery.id): \(delivery.effect)") }
                return .delivered
            }
        }
        return said.value
    }

    @Test func aReleaseIsConfirmedByTheNewBuildAndAnnouncedOnceAcrossACrash() async throws {
        var disk = try lifecycleDisk()
        let clock = TestClock()
        try await withTestAmbient(clock: clock) {
            // The old build: offered, downloaded, verified, applying; then it exits.
            var releases = try await Self.open(disk)
            _ = try await releases.insert(.new(in: .offered, by: .updater, because: "the feed offered 0.55"), as: "0.55")
            try await releases.apply(.download, to: "0.55", by: .updater, because: "the person chose to update")
            try await releases.apply(.verified, to: "0.55", by: .updater, because: "the digest matched")
            try await releases.apply(.apply, to: "0.55", by: .updater, because: "relaunching into 0.55")
            try await releases.close()

            // The successor, at boot: a newer build applies an event to a record the old build wrote.
            clock.jumpWallClock(by: .seconds(30))
            releases = try await Self.open(disk)
            let running = try await releases.apply(.confirm, to: "0.55", by: .successor(pid: 4_242), because: "the router answered 1.2 s after launch")
            #expect(running.written.state == .running)
            // It says so, then dies before anything else is written.
            #expect(try await Self.announce(releases) == ["0.55: \(ReleaseOnThisMac.Effect.announce(.running))"])
            disk = afterCrash(disk)

            // The next launch: the hand-off resumes, and nothing is said twice.
            releases = try await Self.open(disk)
            #expect(try await Self.announce(releases).isEmpty, "\"Updated to 0.55\" is said once")
            // A release is offered only while its record allows it.
            #expect(try await releases.read("0.55")?.state == .running)
            let history = try await releases.history(of: "0.55")
            #expect(history.map(\.by).last == .principal(.successor(pid: 4_242)))
            try LifecycleHistory.verify(history, of: try #require(try await releases.load("0.55")))
            try await releases.close()
        }
    }

    @Test func aRolledBackReleaseStaysRefusedAndIsAnnouncedOnceAcrossACrash() async throws {
        var disk = try lifecycleDisk()
        let clock = TestClock()
        try await withTestAmbient(clock: clock) {
            var releases = try await Self.open(disk)
            _ = try await releases.insert(.new(in: .staged, by: .updater, because: "downloaded and verified"), as: "0.56")
            try await releases.apply(.apply, to: "0.56", by: .updater, because: "relaunching into 0.56")
            try await releases.close()

            // The watchdog is a shell script; its marker becomes an event, once, at boot.
            releases = try await Self.open(disk)
            try await releases.apply(.rollBack, to: "0.56", by: .watchdog, because: "the build never took the pid file")
            disk = afterCrash(disk)   // before anything was said

            releases = try await Self.open(disk)
            #expect(releases.openReport.handOffsResumed == 1)
            #expect(try await Self.announce(releases) == ["0.56: \(ReleaseOnThisMac.Effect.announce(.rolledBack))"])
            #expect(try await Self.announce(releases).isEmpty)
            // A refused release stays refused, across launches and builds: no tombstone to fail to write.
            do throws(LifecycleUpdateError<ReleaseOnThisMac, StoreError>) {
                try await releases.apply(.download, to: "0.56", by: .person, because: "tried again")
                Issue.record("a rolled-back release was offered again")
            } catch .refused(.refused(state: .rolledBack, event: .download, reason: let reason)) {
                #expect(reason == "this release failed its handover once")
            }
            try await releases.close()
        }
    }

    /// A successor that never confirms: the applying state's own two minutes
    /// roll it back, committed at the next launch's `settleDue`.
    @Test func aSuccessorThatNeverConfirmsIsRolledBackByItsTimeout() async throws {
        let disk = try lifecycleDisk()
        let clock = TestClock()
        try await withTestAmbient(clock: clock) {
            var releases = try await Self.open(disk)
            _ = try await releases.insert(.new(in: .staged, by: .updater, because: "downloaded and verified"), as: "0.57")
            try await releases.apply(.apply, to: "0.57", by: .updater, because: "relaunching into 0.57")
            #expect(await releases.nextDue == Moment.now + .seconds(120))
            try await releases.close()
            clock.jumpWallClock(by: .seconds(600))
            releases = try await Self.open(disk)
            #expect(try await releases.settleDue() == 1)
            #expect(try await Self.announce(releases) == ["0.57: \(ReleaseOnThisMac.Effect.announce(.rolledBack))"])
            #expect(try await releases.history(of: "0.57").last?.by == .timeout)
            try await releases.close()
        }
    }

    @Test func theDefinitionWaitsOnlyWhereItSaysSo() {
        let graph = StateGraph<ReleaseOnThisMac.State, ReleaseOnThisMac.Event>.explore(
            ReleaseOnThisMac.self, from: [.offered], events: ReleaseOnThisMac.Event.allCases)
        #expect(graph.isComplete)
        #expect(Set(graph.waitingForever) == [.offered, .staged], "waits the person decides")
        #expect(graph.undeclaredDeadEnds.isEmpty && graph.finalWithExits.isEmpty)
        #expect(graph.stuckTimeouts.isEmpty && graph.timedCycles.isEmpty)
        #expect(graph.unreachable(of: ReleaseOnThisMac.State.allCases).isEmpty)
    }
}
