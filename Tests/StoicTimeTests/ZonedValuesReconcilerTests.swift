import Stoic
import StoicTesting
import StoicTime
import Testing

/// `Reconciler.zonedValues` (design/26, design/30): future zoned values kept
/// right under the rules in force, level-triggered.
@Suite("Reconciler over zoned values")
struct ZonedValuesReconcilerTests {
    enum Events {
        static let starts = Backend.local("test.events-db").readOnly("starts")
        static let restart = Backend.local("test.events-db").idempotent("restart")
    }

    /// An app's stored event starts.
    actor Starts {
        var values: [String: ZonedDateTime]
        var writes: [[String: ZonedDateTime]] = []
        init(_ values: [String: ZonedDateTime]) { self.values = values }
        func read(_ scope: ReconcileScope<String>) -> [String: ZonedDateTime] {
            values.filter { scope.contains($0.key) }
        }
        func update(_ moved: [String: ZonedDateTime]) {
            writes.append(moved)
            values.merge(moved) { $1 }
        }
    }

    static func reconciler(_ starts: Starts, every schedule: Schedule = .fixed(.seconds(86_400))) -> Reconciler<String> {
        Reconciler.zonedValues(
            name: "test.event-starts", reads: Events.starts, writes: Events.restart, every: schedule,
            values: { scope, _ in await starts.read(scope) },
            write: { moved, _ in await starts.update(moved) })
    }

    static func upcoming() throws -> [String: ZonedDateTime] {
        [
            "standup": try ZonedDateTime(Zones.date(2027, 6, 1), Zones.time(9, 0), in: Zones.newYork),
            "launch": try ZonedDateTime(Zones.date(2027, 3, 1), Zones.time(10, 0), in: Zones.kolkata),
        ]
    }

    @Test(.failureMode("design/30", "a future zoned value was written under other rules"))
    func aValueWrittenUnderOtherRulesIsRefreshedThoughTheVersionNeverChanged() async throws {
        // Written by another device, whose rules had daylight saving in 2027.
        let written = try await onTestTime { try Self.upcoming() }
        // This device's rules have none, under the same version label: a
        // sweep that watches the version would never look.
        let rules = Zones.rules()
        abolishDaylightSaving2027(rules)
        rules.version = "2026a"
        try await onTestTime(rules) {
            let starts = Starts(written)
            let reconciler = Self.reconciler(starts)
            let report = try await reconciler.pass()
            #expect(report.applied == 1)
            #expect(await starts.writes.map { $0.keys.sorted() } == [["standup"]], "written in one call")
            #expect(await starts.values["standup"]?.moment == Zones.moment("2027-06-01T14:00:00Z"))
            #expect(await starts.values["standup"]?.local.time == Zones.time(9, 0), "the local time is kept")
            let again = try await reconciler.pass()
            #expect(again.differences == 0, "refreshing a refreshed value changes nothing")
            #expect(reconciler.status.phase == .converged)
        }
    }

    @Test(.failureMode("design/30", "a zoned value's zone is unknown to the rules in force"))
    func aValueInAZoneTheRulesDoNotKnowIsRefusedAndTheOthersWritten() async throws {
        let written = try await onTestTime { try Self.upcoming() }
        let rules = Zones.rules()
        abolishDaylightSaving2027(rules)
        rules.remove(Zones.kolkata)
        try await onTestTime(rules) {
            let starts = Starts(written)
            let reconciler = Self.reconciler(starts)
            let report = try await reconciler.pass()
            #expect(report.applied == 1)
            #expect(await starts.writes.first?.keys.sorted() == ["standup"])
            let stuck = try #require(reconciler.status.stuck.first)
            #expect(stuck.key == "launch")
            guard case .refused(let reason) = stuck.reason else { Issue.record("\(stuck.reason)"); return }
            #expect(reason.contains("Asia/Kolkata"))
        }
    }

    @Test(.failureMode("design/30", "the zone rules change while the app runs"))
    func aChangeOfRulesWhileRunningIsMetByTheNextDailyPass() async throws {
        let rules = Zones.rules()
        let written = try await onTestTime(rules) { try Self.upcoming() }
        let starts = Starts(written)
        _ = try await simulate(seed: 0, limits: SimulationLimits(virtualTime: .seconds(3 * 86_400)), faults: .none, schedule: .uniform) { context in
            try await withZoneRules(rules.rules) {
                let reconciler = Self.reconciler(starts)
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await reconciler.run() }
                    try await Ambient.sleep(for: .seconds(3_600))
                    abolishDaylightSaving2027(rules)        // an OS update, while the app runs
                    while await starts.writes.isEmpty { try await Ambient.sleep(for: .seconds(60)) }
                    #expect(context.clock.now.offset > .seconds(86_000), "at the next daily pass")
                    #expect(context.clock.now.offset <= .seconds(86_460))
                    group.cancelAll()
                }
            }
        }
        #expect(await starts.values["standup"]?.moment == Zones.moment("2027-06-01T14:00:00Z"))
    }

    @Test func aWriteThatIsNotIdempotentIsRefusedWhereTheJobIsMade() async {
        await #expect(processExitsWith: .failure) {
            _ = Reconciler<String>.zonedValues(
                name: "test.bad", reads: Backend.local("test.bad-db").readOnly("read"),
                writes: Backend.local("test.bad-db").notRepeatable("write"),
                values: { _, _ in [:] }, write: { _, _ in })
        }
    }
}
