import Stoic
import StoicSchema
import StoicSchemaTesting
import StoicTesting
import StoicTime
import Testing

/// The time text released builds wrote, read by this one (design/32, design/26):
/// the fixtures in Compatibility/, each recorded by the release in its
/// folder's name, with that release's own code, on the scripted rules of
/// `Zones.rules()`.
@Suite("Time text: what released builds wrote")
struct TimeCompatibilityTests {
    /// What a fixture named `name` must read as.
    static func verify<Value: Equatable & Sendable>(_ named: [String: Value]) -> @Sendable (CompatibilityFixture, Value) -> [String] {
        { fixture, value in
            guard let expected = named[fixture.name] else { return ["no value is named \"\(fixture.name)\""] }
            return value == expected ? [] : ["reads as \(value), not as \(expected)"]
        }
    }

    @Test func aMomentReadsAsTheReleaseWroteIt() async throws {
        try await onTestTime {
            let whole = Zones.moment("2026-01-01T00:00:00Z"), fraction = Zones.moment("2027-03-14T07:30:00.25Z")
            let before1970 = Zones.moment("1969-07-20T20:17:40Z")
            let report = expectCompatibility(
                Moment.schema, format: "moment", samples: ["whole-second": whole, "fraction": fraction, "before-1970": before1970],
                verify: Self.verify(["whole-second": whole, "fraction": fraction, "before-1970": before1970]))
            #expect(report.read == 3)
        }
    }

    @Test func aPlainDateReadsAsTheReleaseWroteIt() async throws {
        try await onTestTime {
            let february = Zones.date(2027, 2, 28), leap = Zones.date(2028, 2, 29)
            let report = expectCompatibility(
                PlainDate.schema, format: "plain-date", samples: ["end-of-february": february, "leap-day": leap],
                verify: Self.verify(["end-of-february": february, "leap-day": leap]))
            #expect(report.read == 2)
        }
    }

    @Test func aPeriodReadsAsTheReleaseWroteIt() {
        let full = Period(years: 1, months: 2, days: 10), days = Period(days: 3), back = Period(months: -1)
        let report = expectCompatibility(
            Period.schema, format: "period", samples: ["years-months-days": full, "days": days, "back-a-month": back],
            verify: Self.verify(["years-months-days": full, "days": days, "back-a-month": back]))
        #expect(report.read == 3)
    }

    @Test func aZonedDateTimeReadsAsTheReleaseWroteIt() async throws {
        try await onTestTime {
            // The values the fixtures hold, by name: a summer time, a zone
            // with a half-hour offset, and a wall time in a spring-forward gap.
            let summer = try ZonedDateTime(Zones.date(2027, 6, 1), Zones.time(9, 0), in: Zones.newYork)
            let kolkata = try ZonedDateTime(Zones.date(2027, 3, 1), Zones.time(10, 30), in: Zones.kolkata)
            let gap = try ZonedDateTime(Zones.local(2027, 3, 14, 2, 30), in: Zones.newYork)
            let report = expectCompatibility(
                ZonedDateTime.schema, format: "zoned-date-time",
                samples: ["new-york-summer": summer, "kolkata": kolkata, "new-york-gap": gap],
                verify: Self.verify(["new-york-summer": summer, "kolkata": kolkata, "new-york-gap": gap]))
            #expect(report.read == 3)
        }
    }
}
