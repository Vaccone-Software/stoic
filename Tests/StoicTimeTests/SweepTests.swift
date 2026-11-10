import Foundation
import Stoic
import StoicTesting
import StoicTime
import Testing

@Suite("Zone rules sweep")
struct SweepTests {
    /// The app's upcoming events: a June meeting in New York (moved by
    /// `2026b`), a March one in Kolkata (never moved), and one in the past.
    private static func upcoming() throws -> [String: ZonedDateTime] {
        [
            "standup": try ZonedDateTime(Zones.date(2027, 6, 1), Zones.time(9, 0), in: Zones.newYork),
            "launch": try ZonedDateTime(Zones.date(2027, 3, 1), Zones.time(10, 0), in: Zones.kolkata),
            "retro": try ZonedDateTime(Zones.date(2025, 6, 1), Zones.time(9, 0), in: Zones.newYork),
        ]
    }

    @Test(.failureMode("design/26", "the rules version changes between launches"))
    func aChangedVersionSweepsOnceAndRecordsIt() async throws {
        let rules = Zones.rules()
        let events = RecordingInstrumentation()
        try await onTestTime(rules, events: events) {
            var stored = try Self.upcoming()
            // The first run: nothing swept yet, so it sweeps under 2026a,
            // where nothing moves.
            var sweep = ZoneRulesSweep()
            #expect(sweep.isDue)
            let first = await sweep.run(values: { stored }) { _ in Issue.record("nothing moved under the same rules") }
            #expect(first?.summary == "none → 2026a: given 3, moved 0, unresolved 0")
            #expect(sweep.lastSweptVersion == "2026a" && !sweep.isDue)

            // An OS update between launches: the sweep, persisted with the
            // app's settings, comes back and finds a new version.
            let persisted = try JSONDecoder().decode(ZoneRulesSweep.self, from: JSONEncoder().encode(sweep))
            #expect(persisted == sweep)
            abolishDaylightSaving2027(rules)
            sweep = persisted
            var handed: [[String: ZonedDateTime]] = []
            let second = await sweep.run(values: { stored }) { moved in
                handed.append(moved)
                stored.merge(moved) { $1 }
            }
            #expect(second?.summary == "2026a → 2026b: given 3, moved 1, unresolved 0")
            #expect(handed.count == 1, "handed over once")
            #expect(handed.first?.keys.sorted() == ["standup"])
            #expect(stored["standup"]?.moment == Zones.moment("2027-06-01T14:00:00Z"))
            #expect(stored["standup"]?.local.time == Zones.time(9, 0))
            #expect(stored["retro"]?.moment == Zones.moment("2025-06-01T14:00:00Z"), "the past one is final")
            #expect(sweep.lastSweptVersion == "2026b")

            // The same launch, or the next, under the same rules: nothing.
            let third = await sweep.run(values: { stored }) { _ in Issue.record("swept twice") }
            #expect(third == nil)
        }
        let changes = events.events(named: "time.zone_rules_changed")
        #expect(changes.count == 2)
        #expect(changes.last?.level == .notice)
        #expect(changes.last?["previous"]?.description == "2026a")
        #expect(changes.last?["version"]?.description == "2026b")
        #expect(changes.last?["given"]?.description == "3")
        #expect(changes.last?["moved"]?.description == "1")
    }

    @Test(.failureMode("design/26", "the rules version is unchanged"))
    func anUnchangedVersionDoesNothingAndAsksForNothing() async throws {
        let events = RecordingInstrumentation()
        try await onTestTime(events: events) {
            var sweep = ZoneRulesSweep(lastSweptVersion: "2026a")
            #expect(!sweep.isDue)
            let report = try await sweep.run(values: { () throws -> [String: ZonedDateTime] in
                Issue.record("the values were asked for")
                return [:]
            }) { _ in Issue.record("apply was called") }
            #expect(report == nil)
            #expect(sweep.lastSweptVersion == "2026a")
        }
        #expect(events.events(named: "time.zone_rules_changed").isEmpty)
    }

    @Test func aFailedApplyLeavesTheVersionForTheNextRun() async throws {
        struct Unwritable: Error {}
        let rules = Zones.rules()
        try await onTestTime(rules) {
            let values = try Self.upcoming()
            var sweep = ZoneRulesSweep(lastSweptVersion: "2026a")
            abolishDaylightSaving2027(rules)
            do throws(Unwritable) {
                try await sweep.run(values: { () throws(Unwritable) in values }) { _ throws(Unwritable) in throw Unwritable() }
                Issue.record("apply's failure was not thrown")
            } catch {}
            #expect(sweep.lastSweptVersion == "2026a", "not recorded: the next run tries again")
            #expect(sweep.isDue)
        }
    }

    /// The sweep refreshes each value by the policy it was made with: the
    /// second 01:30 of an overlap is still the second after a rule change
    /// that keeps the overlap and moves its instants.
    @Test(.failureMode("design/26", "the sweep refreshes a value made with a policy"))
    func theSweepKeepsTheOccurrenceEachValueWasMadeWith() async throws {
        let rules = Zones.rules()
        try await onTestTime(rules) {
            let values: [String: ZonedDateTime] = [
                "second": try ZonedDateTime(Zones.local(2027, 11, 7, 1, 30), in: Zones.newYork, resolving: .later),
                "first": try ZonedDateTime(Zones.local(2027, 11, 7, 1, 30), in: Zones.newYork, resolving: .earlier),
            ]
            var sweep = ZoneRulesSweep(lastSweptVersion: "2026a")
            deepenFallBack2027(rules)
            var moved: [String: ZonedDateTime] = [:]
            let report = await sweep.run(values: { values }) { moved = $0 }
            #expect(report?.moved == 1)
            #expect(moved.keys.sorted() == ["second"], "the first 01:30 did not move")
            #expect(moved["second"]?.resolution == .overlap(chose: .later))
            #expect(moved["second"]?.moment == Zones.moment("2027-11-07T07:30:00Z"))

            // A policy given overrides each value's own.
            var again = ZoneRulesSweep(lastSweptVersion: "2026a")
            await again.run(resolving: .earlier, values: { values }) { moved = $0 }
            #expect(moved["second"]?.moment == Zones.moment("2027-11-07T05:30:00Z"))
        }
    }

    @Test func aValueTheNewRulesCannotResolveIsCountedAndLeft() async throws {
        let rules = Zones.rules()
        try await onTestTime(rules) {
            var values = try Self.upcoming()
            values["moon"] = try ZonedDateTime(parsing: "2027-06-01T09:00:00+00:00[Moon/Tranquility]")
            var sweep = ZoneRulesSweep(lastSweptVersion: "2026a")
            abolishDaylightSaving2027(rules)
            let report = await sweep.run(values: { values }) { moved in #expect(moved.keys.sorted() == ["standup"]) }
            #expect(report?.moved == 1 && report?.unresolved == 1)
            #expect(sweep.lastSweptVersion == "2026b")
        }
    }
}

extension ZoneRulesSweep.Report {
    var summary: String {
        "\(previousVersion ?? "none") → \(version): given \(given), moved \(moved), unresolved \(unresolved)"
    }
}
