import Foundation
import Stoic
import StoicTesting
import StoicTime
import Testing

/// The only tests that ask the system's zone rules, as design/26 lists
/// them: known transitions of New York in 2027, Lord Howe's half-hour
/// change, and a zone without daylight saving. They check the seam to
/// Foundation, not the arithmetic, which every other test runs on scripted
/// rules. None reads the machine's own zone or today's date.
@Suite("System zone rules")
struct SystemZoneRulesTests {
    private func onSystemRules<R>(_ body: () throws -> R) rethrows -> R {
        try withZoneRules(.system) { try body() }
    }

    @Test func newYork2027() throws {
        try onSystemRules {
            let rules = ZoneRules.current
            #expect(try rules.offset(of: Zones.newYork, at: Zones.moment("2027-01-15T12:00:00Z")) == Zones.hours(-5))
            #expect(try rules.offset(of: Zones.newYork, at: Zones.moment("2027-07-15T12:00:00Z")) == Zones.hours(-4))

            let gap = try ZonedDateTime(Zones.local(2027, 3, 14, 2, 30), in: Zones.newYork)
            #expect(gap.resolution == .gap(shiftedBy: .seconds(3600)))
            #expect(gap.moment == Zones.moment("2027-03-14T07:30:00Z"))

            let overlap = try ZonedDateTime(Zones.local(2027, 11, 7, 1, 30), in: Zones.newYork, resolving: .later)
            #expect(overlap.resolution == .overlap(chose: .later))
            #expect(overlap.moment == Zones.moment("2027-11-07T06:30:00Z"))

            let start = try ZonedDateTime(Zones.date(2027, 3, 14), Zones.time(9, 0), in: Zones.newYork)
            #expect(start.description == "2027-03-14T09:00:00-04:00[America/New_York]")
            #expect(try !start.isStale(now: .epoch))
        }
    }

    @Test func lordHowesHalfHourChange() throws {
        try onSystemRules {
            let gap = try ZonedDateTime(Zones.local(2027, 10, 3, 2, 15), in: Zones.lordHowe)
            #expect(gap.resolution == .gap(shiftedBy: .seconds(1800)))
            #expect(gap.moment == Zones.moment("2027-10-02T15:45:00Z"))
            let overlap = try ZonedDateTime(Zones.local(2027, 4, 4, 1, 45), in: Zones.lordHowe)
            #expect(overlap.resolution == .overlap(chose: .earlier))
            #expect(overlap.offset == Zones.hours(11))
        }
    }

    @Test func aZoneWithoutDaylightSaving() throws {
        try onSystemRules {
            for month in [1, 4, 7, 10] {
                let zoned = try ZonedDateTime(Zones.date(2027, month, 1), Zones.time(9, 0), in: Zones.kolkata)
                #expect(zoned.resolution == .exact && zoned.offset == Zones.hours(5.5))
            }
            #expect(throws: TimeError.unknownZone("Mars/Olympus_Mons")) {
                try ZonedDateTime(Zones.local(2027, 1, 1, 9, 0), in: "Mars/Olympus_Mons")
            }
        }
    }

    @Test func theSystemRulesReportTheirVersionAndTheDevicesZone() {
        #expect(!ZoneRules.system.version.isEmpty)
        #expect(ZoneRules.system.version == TimeZone.timeZoneDataVersion)
        #expect(ZoneRules.system.deviceZone.identifier == TimeZone.autoupdatingCurrent.identifier)
        #expect(ZoneRules.current.version == ZoneRules.system.version, "the system's, outside withZoneRules")
    }

    @Test func dateAndTimeZoneConvert() throws {
        let moment = Zones.moment("2026-11-09T18:34:12.425Z")
        #expect(moment.date == Date(timeIntervalSinceReferenceDate: 815_942_052.425))
        #expect(Moment(moment.date).date == moment.date)
        let error = moment.duration(to: Moment(moment.date))
        #expect(error > .microseconds(-1) && error < .microseconds(1), "a Date holds about a tenth of a microsecond now")
        var random = RandomSource.seeded(2001).generator()
        for _ in 0..<10_000 {
            let date = Date(timeIntervalSinceReferenceDate: Double.random(in: -6e10...2.5e11, using: &random))
            #expect(Moment(date).date == date)
        }
        #expect(Moment(Date(timeIntervalSince1970: 0)) == .epoch)
        let real = Moment(Date())
        let apart = real.duration(to: WallClock.system.now)
        #expect(apart > .seconds(-1) && apart < .seconds(1), "Foundation's now and CLOCK_REALTIME agree")

        #expect(TimeZone(Zones.newYork)?.identifier == "America/New_York")
        let offsetZone: TimeZoneID = "+05:30"
        #expect(TimeZone(offsetZone)?.secondsFromGMT() == 19_800)
        #expect(TimeZone(TimeZoneID.utc)?.secondsFromGMT() == 0)
        #expect(TimeZoneID(TimeZone(identifier: "Europe/London")!) == "Europe/London")
    }
}
