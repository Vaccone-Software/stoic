import Stoic
import StoicTesting
import StoicTime
import Testing

/// Every test here runs on scripted zone rules and the test clock's wall
/// clock: none depends on the machine's zone database, the zone it is set
/// to, or today's date. Only `SystemZoneRulesTests` asks the system.
enum Zones {
    static let newYork: TimeZoneID = "America/New_York"
    static let lordHowe: TimeZoneID = "Australia/Lord_Howe"
    static let kolkata: TimeZoneID = "Asia/Kolkata"

    static func moment(_ text: String) -> Moment {
        guard let moment = Moment(rfc3339: text) else { preconditionFailure("\(text) is not a moment") }
        return moment
    }

    static func hours(_ hours: Double) -> Duration {
        .seconds(Int(hours * 3600))
    }

    /// New York as the IANA database has it for 2026 and 2027: EST (-05:00),
    /// and EDT (-04:00) from the second Sunday of March at 02:00 to the first
    /// Sunday of November at 02:00.
    static let newYorkTransitions: [ScriptedZoneRules.Transition] = [
        .init(at: moment("2026-03-08T07:00:00Z"), offset: hours(-4)),
        .init(at: moment("2026-11-01T06:00:00Z"), offset: hours(-5)),
        .init(at: moment("2027-03-14T07:00:00Z"), offset: hours(-4)),
        .init(at: moment("2027-11-07T06:00:00Z"), offset: hours(-5)),
    ]

    /// Lord Howe Island: +10:30, and +11:00 (half an hour of daylight
    /// saving) until the first Sunday of April at 02:00 and from the first
    /// Sunday of October at 02:00.
    static let lordHoweTransitions: [ScriptedZoneRules.Transition] = [
        .init(at: moment("2027-04-03T15:00:00Z"), offset: hours(10.5)),
        .init(at: moment("2027-10-02T15:30:00Z"), offset: hours(11)),
    ]

    /// Rules of version `2026a` that know New York, Lord Howe and Kolkata,
    /// on a device set to New York.
    static func rules(version: String = "2026a") -> ScriptedZoneRules {
        let rules = ScriptedZoneRules(version: version, deviceZone: newYork)
        rules.define(newYork, offset: hours(-5), transitions: newYorkTransitions)
        rules.define(lordHowe, offset: hours(11), transitions: lordHoweTransitions)
        rules.define(kolkata, offset: hours(5.5))
        return rules
    }

    static func date(_ year: Int, _ month: Int, _ day: Int) -> PlainDate {
        do { return try PlainDate(year, month, day) } catch { preconditionFailure("\(error)") }
    }

    static func time(_ hour: Int, _ minute: Int, _ second: Int = 0) -> PlainTime {
        do { return try PlainTime(hour, minute, second) } catch { preconditionFailure("\(error)") }
    }

    static func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> PlainDateTime {
        PlainDateTime(date(year, month, day), time(hour, minute))
    }
}

/// Runs `body` on `rules` and a test clock whose wall clock starts at
/// 2026-01-01T00:00:00Z, recording events.
func onTestTime<R>(
    _ rules: ScriptedZoneRules = Zones.rules(),
    clock: TestClock = TestClock(),
    events: RecordingInstrumentation = RecordingInstrumentation(),
    _ body: () async throws -> R
) async throws -> R {
    try await withTestAmbient(clock: clock, events: events) {
        try await withZoneRules(rules.rules) {
            try await body()
        }
    }
}
