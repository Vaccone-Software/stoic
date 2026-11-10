import Stoic
import StoicTesting
import StoicTime
import Testing

@Suite("Time under test")
struct TestTimeTests {
    /// The wall clock is the test clock's: `Moment.now` and today move when
    /// the test moves time, and only then.
    @Test(.failureMode("design/26", "a test advances its clock"))
    func advancingTheTestClockMovesNowAndToday() async throws {
        let clock = TestClock()
        try await onTestTime(clock: clock) { () async throws in
            #expect(Moment.now == Zones.moment("2026-01-01T00:00:00Z"))
            // 19:00 on New Year's Eve in New York; already New Year's Day in
            // Kolkata.
            #expect(try PlainDate.today(in: Zones.newYork) == Zones.date(2025, 12, 31))
            #expect(try PlainDate.today(in: Zones.kolkata) == Zones.date(2026, 1, 1))
            #expect(try PlainDate.today(in: .device) == Zones.date(2025, 12, 31), "the scripted device is in New York")

            await clock.advance(by: .seconds(5 * 3600))
            #expect(Moment.now == Zones.moment("2026-01-01T05:00:00Z"))
            #expect(try PlainDate.today(in: Zones.newYork) == Zones.date(2026, 1, 1))

            await clock.advance(by: .seconds(86_400 * 72))
            #expect(try PlainDate.today(in: .utc) == Zones.date(2026, 3, 14))
        }
    }

    @Test func theDeviceZoneComesFromTheRulesNotTheMachine() async throws {
        let rules = Zones.rules()
        try await onTestTime(rules) { () async throws in
            #expect(TimeZoneID.device == Zones.newYork)
            rules.deviceZone = Zones.lordHowe
            #expect(TimeZoneID.device == Zones.lordHowe, "travel")
            #expect(try PlainDate.today(in: .device) == Zones.date(2026, 1, 1))
        }
    }

    @Test func withZoneRulesBindsSynchronousCodeToo() throws {
        let rules = Zones.rules(version: "sync")
        let version = withZoneRules(rules.rules) { ZoneRules.current.version }
        #expect(version == "sync")
        let offset = try withZoneRules(rules.rules) { () throws(TimeError) in
            try ZoneRules.current.offset(of: Zones.kolkata, at: .epoch)
        }
        #expect(offset == Zones.hours(5.5))
    }
}
