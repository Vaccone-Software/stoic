import Foundation
import Stoic
import StoicTesting
import StoicTime
import Testing

@Suite("Zoned date-times")
struct ZonedDateTimeTests {
    // MARK: Resolution

    @Test func anOrdinaryLocalTimeResolvesExactly() async throws {
        let start = try await onTestTime {
            try ZonedDateTime(Zones.date(2027, 3, 14), Zones.time(9, 0), in: Zones.newYork)
        }
        #expect(start.moment == Zones.moment("2027-03-14T13:00:00Z"))
        #expect(start.offset == Zones.hours(-4))
        #expect(start.resolution == .exact)
        #expect(start.local.time.description == "09:00" && start.zone == Zones.newYork)
        #expect(start.description == "2027-03-14T09:00:00-04:00[America/New_York]")
    }

    /// 02:30 on 14 March 2027 does not exist in New York: the clocks go from
    /// 01:59:59 EST to 03:00:00 EDT.
    @Test func aLocalTimeInAGapIsResolvedByThePolicyAndSaysSo() async throws {
        let events = RecordingInstrumentation()
        let night = Zones.local(2027, 3, 14, 2, 30)
        try await onTestTime(events: events) {
            let compatible = try ZonedDateTime(night, in: Zones.newYork)
            #expect(compatible.moment == Zones.moment("2027-03-14T07:30:00Z"), "03:30 EDT, after the gap")
            #expect(compatible.resolution == .gap(shiftedBy: .seconds(3600)))
            #expect(compatible.local == night, "the local time is kept as it was meant")
            #expect(try compatible.moment.in(Zones.newYork).local == Zones.local(2027, 3, 14, 3, 30))

            let later = try ZonedDateTime(night, in: Zones.newYork, resolving: .later)
            #expect(later.moment == compatible.moment && later.resolution == compatible.resolution)

            let earlier = try ZonedDateTime(night, in: Zones.newYork, resolving: .earlier)
            #expect(earlier.moment == Zones.moment("2027-03-14T06:30:00Z"), "01:30 EST, before the gap")
            #expect(earlier.resolution == .gap(shiftedBy: .seconds(-3600)))

            #expect(throws: TimeError.inGap(night, Zones.newYork)) {
                try ZonedDateTime(night, in: Zones.newYork, resolving: .reject)
            }
            // The edges: 02:00 is in the gap, 03:00 is not.
            #expect(try ZonedDateTime(Zones.local(2027, 3, 14, 2, 0), in: Zones.newYork).resolution == .gap(shiftedBy: .seconds(3600)))
            #expect(try ZonedDateTime(Zones.local(2027, 3, 14, 3, 0), in: Zones.newYork).resolution == .exact)
            #expect(try ZonedDateTime(Zones.local(2027, 3, 14, 1, 59), in: Zones.newYork).resolution == .exact)
        }
        let gaps = events.events(named: "time.resolved_in_gap")
        #expect(gaps.count == 4, "every resolution that landed in a gap, and none that was refused")
        #expect(gaps.first?["zone"]?.description == "America/New_York")
        #expect(gaps.first?["shift"]?.description == Duration.seconds(3600).description)
        #expect(gaps.first?.level == .info)
    }

    /// 01:30 on 7 November 2027 happens twice in New York: once in EDT,
    /// then again an hour later in EST.
    @Test func aLocalTimeInAnOverlapIsResolvedByThePolicyAndSaysSo() async throws {
        let events = RecordingInstrumentation()
        let night = Zones.local(2027, 11, 7, 1, 30)
        try await onTestTime(events: events) {
            let compatible = try ZonedDateTime(night, in: Zones.newYork)
            #expect(compatible.moment == Zones.moment("2027-11-07T05:30:00Z"), "the first, in EDT")
            #expect(compatible.resolution == .overlap(chose: .earlier))
            #expect(compatible.offset == Zones.hours(-4))

            let earlier = try ZonedDateTime(night, in: Zones.newYork, resolving: .earlier)
            #expect(earlier == compatible)

            let later = try ZonedDateTime(night, in: Zones.newYork, resolving: .later)
            #expect(later.moment == Zones.moment("2027-11-07T06:30:00Z"), "the second, in EST")
            #expect(later.resolution == .overlap(chose: .later))
            #expect(later.description == "2027-11-07T01:30:00-05:00[America/New_York]")

            #expect(throws: TimeError.inOverlap(night, Zones.newYork)) {
                try ZonedDateTime(night, in: Zones.newYork, resolving: .reject)
            }
            // Seen from the instants, each is that local time and says which.
            #expect(try later.moment.in(Zones.newYork).resolution == .overlap(chose: .later))
            #expect(try compatible.moment.in(Zones.newYork).resolution == .overlap(chose: .earlier))
        }
        #expect(events.events(named: "time.resolved_in_gap").isEmpty)
    }

    @Test func halfHourDaylightSavingIsAGapAndAnOverlapOfHalfAnHour() async throws {
        try await onTestTime {
            let gap = try ZonedDateTime(Zones.local(2027, 10, 3, 2, 15), in: Zones.lordHowe)
            #expect(gap.resolution == .gap(shiftedBy: .seconds(1800)))
            #expect(try gap.moment.in(Zones.lordHowe).local == Zones.local(2027, 10, 3, 2, 45))
            let overlap = try ZonedDateTime(Zones.local(2027, 4, 4, 1, 45), in: Zones.lordHowe, resolving: .later)
            #expect(overlap.resolution == .overlap(chose: .later))
            #expect(overlap.offset == Zones.hours(10.5))
        }
    }

    @Test func aZoneTheRulesDoNotKnowIsAnErrorAtResolution() async throws {
        let unknown: TimeZoneID = "Mars/Olympus_Mons"
        try await onTestTime {
            #expect(throws: TimeError.unknownZone(unknown)) {
                try ZonedDateTime(Zones.date(2027, 3, 14), Zones.time(9, 0), in: unknown)
            }
            #expect(throws: TimeError.unknownZone(unknown)) { try Moment.now.in(unknown) }
            #expect(throws: TimeError.unknownZone(unknown)) { try PlainDate.today(in: unknown) }
            // A value read from text names it without asking the rules; using
            // it asks them.
            let read = try ZonedDateTime(parsing: "2027-03-14T09:00:00+01:00[Mars/Olympus_Mons]")
            #expect(throws: TimeError.unknownZone(unknown)) { try read.isStale() }
            #expect(throws: TimeError.unknownZone(unknown)) { try read.refreshed() }
        }
    }

    // MARK: Rule changes

    /// New York's rules change in a release `2026b`: no daylight saving in
    /// 2027. A June event resolved under `2026a` was 09:00 EDT, 13:00Z; it is
    /// now 09:00 EST, 14:00Z.
    @Test func aRuleChangeMakesAFutureValueStaleAndRefreshingKeepsItsLocalTime() async throws {
        let rules = Zones.rules()
        let clock = TestClock()
        try await onTestTime(rules, clock: clock) {
            let event = try ZonedDateTime(Zones.date(2027, 6, 1), Zones.time(9, 0), in: Zones.newYork)
            #expect(event.moment == Zones.moment("2027-06-01T13:00:00Z"))
            #expect(try !event.isStale())

            abolishDaylightSaving2027(rules)
            #expect(try event.isStale())
            let refreshed = try event.refreshed()
            #expect(refreshed.local == event.local && refreshed.zone == event.zone)
            #expect(refreshed.moment == Zones.moment("2027-06-01T14:00:00Z"))
            #expect(refreshed.resolution == .exact)
            #expect(try !refreshed.isStale())
            #expect(refreshed.description == "2027-06-01T09:00:00-05:00[America/New_York]")
        }
    }

    @Test func aRuleChangeLeavesAPastValueFinal() async throws {
        let rules = Zones.rules()
        let clock = TestClock()
        try await onTestTime(rules, clock: clock) {
            let event = try ZonedDateTime(Zones.date(2027, 6, 1), Zones.time(9, 0), in: Zones.newYork)
            // The event happens, and time moves past it.
            clock.jumpWallClock(to: Zones.moment("2027-07-01T00:00:00Z"))
            abolishDaylightSaving2027(rules)
            #expect(try !event.isStale(), "past values are final")
            let refreshed = try event.refreshed()
            #expect(refreshed == event && refreshed.resolution == event.resolution)
            #expect(refreshed.moment == Zones.moment("2027-06-01T13:00:00Z"), "it happened at the instant it was resolved to")
            // At the very instant, it is final too.
            #expect(try !event.isStale(now: event.moment))
        }
    }

    /// Release `2026c` starts New York's 2027 daylight saving on 4 April at
    /// 02:00 instead of 14 March: an event stored for 02:30 on 4 April now
    /// falls in the gap.
    @Test func aRuleChangeThatMovesAStoredTimeIntoAGapIsResolvedByThePolicy() async throws {
        let rules = Zones.rules()
        let events = RecordingInstrumentation()
        try await onTestTime(rules, events: events) {
            let event = try ZonedDateTime(Zones.local(2027, 4, 4, 2, 30), in: Zones.newYork)
            #expect(event.resolution == .exact)
            #expect(event.moment == Zones.moment("2027-04-04T06:30:00Z"))

            rules.version = "2026c"
            rules.define(
                Zones.newYork, offset: Zones.hours(-5),
                transitions: [
                    .init(at: Zones.moment("2026-03-08T07:00:00Z"), offset: Zones.hours(-4)),
                    .init(at: Zones.moment("2026-11-01T06:00:00Z"), offset: Zones.hours(-5)),
                    .init(at: Zones.moment("2027-04-04T07:00:00Z"), offset: Zones.hours(-4)),
                    .init(at: Zones.moment("2027-11-07T06:00:00Z"), offset: Zones.hours(-5)),
                ])
            #expect(try event.isStale())
            let refreshed = try event.refreshed()
            #expect(refreshed.local == event.local, "the organiser's 02:30 is kept")
            #expect(refreshed.resolution == .gap(shiftedBy: .seconds(3600)))
            #expect(refreshed.moment == Zones.moment("2027-04-04T07:30:00Z"), "03:30 EDT")
            #expect(throws: TimeError.inGap(event.local, Zones.newYork)) { try event.refreshed(resolving: .reject) }
        }
        #expect(events.events(named: "time.resolved_in_gap").count == 1)
    }

    /// Staleness re-resolves by the policy a value was made with: the later
    /// 01:30 of an overlap is not stale for not being the compatible one, and
    /// a value read from text is stale only if no policy gives its instant.
    @Test func stalenessFollowsThePolicyThatMadeTheValue() async throws {
        try await onTestTime {
            let second = try ZonedDateTime(Zones.local(2027, 11, 7, 1, 30), in: Zones.newYork, resolving: .later)
            #expect(try !second.isStale())
            let before = try ZonedDateTime(Zones.local(2027, 3, 14, 2, 30), in: Zones.newYork, resolving: .earlier)
            #expect(try !before.isStale())
            let read = try ZonedDateTime(parsing: before.description)
            #expect(read.resolution == .decoded && read == before)
            #expect(try !read.isStale(), "01:30 EST is what .earlier makes of 02:30")
        }
    }

    /// Until it is refreshed, a stale value sorts by the instant it was
    /// resolved to; its local time and zone, which are what is shown, are
    /// still right.
    @Test func aStaleValueSortsByItsOldInstantAndStillShowsTheRightTime() async throws {
        let rules = Zones.rules()
        try await onTestTime(rules) {
            let nineInNewYork = try ZonedDateTime(Zones.date(2027, 6, 1), Zones.time(9, 0), in: Zones.newYork)
            // 13:30Z: between 09:00 EDT (13:00Z) and 09:00 EST (14:00Z).
            let elsewhere = try ZonedDateTime(Zones.date(2027, 6, 1), Zones.time(19, 0), in: Zones.kolkata)
            #expect(elsewhere.moment == Zones.moment("2027-06-01T13:30:00Z"))

            abolishDaylightSaving2027(rules)
            let stale = [elsewhere, nineInNewYork].sorted { $0.moment < $1.moment }
            #expect(stale.map(\.zone) == [Zones.newYork, Zones.kolkata], "sorted by the old instant, an hour out")
            #expect(stale[0].local.time.description == "09:00", "the time shown is the one meant")

            let refreshed = try [elsewhere, nineInNewYork].map { try $0.refreshed() }.sorted { $0.moment < $1.moment }
            #expect(refreshed.map(\.zone) == [Zones.kolkata, Zones.newYork], "refreshed, it sorts where it belongs")
        }
    }

    // MARK: Text

    /// The text names New York with an offset of -04:00 for a day in
    /// January, when New York is at -05:00: written under other rules.
    @Test func textWithAnOffsetItsZoneDoesNotGiveDecodesStale() async throws {
        try await onTestTime {
            let text = "2027-01-20T09:00:00-04:00[America/New_York]"
            let read = try ZonedDateTime(parsing: text)
            #expect(read.local == Zones.local(2027, 1, 20, 9, 0))
            #expect(read.moment == Zones.moment("2027-01-20T13:00:00Z"), "the offset is the instant")
            #expect(read.resolution == .decoded)
            #expect(read.description == text, "written back as it was read")
            #expect(try read.isStale(), "not refused: stale")
            let refreshed = try read.refreshed()
            #expect(refreshed.moment == Zones.moment("2027-01-20T14:00:00Z") && refreshed.resolution == .exact)

            let decoded = try JSONDecoder().decode([ZonedDateTime].self, from: Data(#"["\#(text)"]"#.utf8))[0]
            #expect(decoded == read)
            #expect(try !ZonedDateTime(parsing: "2027-01-20T09:00:00-05:00[America/New_York]").isStale())
        }
    }

    @Test func zonedTextFollowsRFC9557() throws {
        let plain = "2027-03-14T09:00:00-04:00[America/New_York]"
        #expect(try ZonedDateTime(parsing: "2027-03-14T09:00:00-04:00[!America/New_York]").description == plain)
        #expect(try ZonedDateTime(parsing: "2027-03-14T09:00:00-04:00[America/New_York][u-ca=iso8601]").description == plain)
        #expect(try ZonedDateTime(parsing: "2027-03-14T09:00:00-04:00[America/New_York][x-other=thing]").description == plain)
        #expect(try ZonedDateTime(parsing: "2027-03-14T09:00:00.5-04:00[America/New_York]").local.time.nanosecond == 500_000_000)
        let lmt = try ZonedDateTime(parsing: "1883-11-18T12:00:00-04:56:02[America/New_York]")
        #expect(lmt.offset == .seconds(-17_762) && lmt.description == "1883-11-18T12:00:00-04:56:02[America/New_York]")
        let refusals: [(String, String)] = [
            ("2027-03-14T13:00:00Z[America/New_York]", "its offset is `Z`"),
            ("2027-03-14T09:00:00-04:00", "it has no zone in brackets"),
            ("2027-03-14T09:00-04:00[America/New_York]", "it has no seconds"),
            ("2027-03-14T09:00:00-04:00[America/New York]", "no spaces"),
            ("2027-03-14T09:00:00-04:00[America/New_York", "not closed"),
            ("2027-03-14T09:00:00-04:00[America/New_York][u-ca=hebrew]", "the calendar hebrew"),
            ("2027-03-14T09:00:00-04:00[America/New_York][!x-other=thing]", "critical tag"),
            ("2027-03-14T09:00:00-04:00[u-ca=iso8601]", "must be the zone"),
            ("2027-02-30T09:00:00-05:00[America/New_York]", "has 28 days"),
        ]
        for (text, reason) in refusals {
            let error = #expect(throws: TimeError.self, "\(text)") { try ZonedDateTime(parsing: text) }
            #expect(error.map { "\($0)" }?.contains(reason) == true, "\(text): \(String(describing: error))")
        }
    }

    // MARK: Properties

    /// In a zone with one fixed offset there are no gaps or overlaps:
    /// resolving a local time and reading the instant back is the identity,
    /// both ways, and every value's text reads back as itself.
    @Test func fixedOffsetZonesResolveAndReadBackAsTheIdentity() async throws {
        var random = RandomSource.seeded(9557).generator()
        try await onTestTime {
            for _ in 0..<5_000 {
                let minutes = Int.random(in: -(23 * 60 + 59)...(23 * 60 + 59), using: &random)
                let sign = minutes < 0 ? "-" : "+"
                func two(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
                let zone = try TimeZoneID("\(sign)\(two(abs(minutes) / 60)):\(two(abs(minutes) % 60))")
                let local = PlainDateTime(
                    try randomDate(&random),
                    try PlainTime(
                        Int.random(in: 0...23, using: &random), Int.random(in: 0...59, using: &random),
                        Int.random(in: 0...59, using: &random), nanosecond: Int.random(in: 0..<1_000_000_000, using: &random)))
                let zoned = try ZonedDateTime(local, in: zone)
                #expect(zoned.resolution == .exact)
                #expect(zoned.offset == .seconds(minutes * 60))
                #expect(try zoned.moment.in(zone).local == local)
                #expect(try zoned.moment.in(zone) == zoned)
                #expect(try ZonedDateTime(parsing: zoned.description) == zoned)
                #expect(try roundTrip(zoned) == zoned)
                #expect(try roundTrip(zoned.moment) == zoned.moment)
            }
        }
    }

    /// In New York, every instant read as a local time and resolved back by
    /// the policy that matches it gives the same instant, across both
    /// transitions of 2027.
    @Test func instantsReadInAZoneResolveBackToThemselves() async throws {
        try await onTestTime {
            var instant = Zones.moment("2027-03-13T00:00:00Z")
            while instant < Zones.moment("2027-11-09T00:00:00Z") {
                let seen = try instant.in(Zones.newYork)
                let policy: Disambiguation = seen.resolution == .overlap(chose: .later) ? .later : .earlier
                #expect(try ZonedDateTime(seen.local, in: Zones.newYork, resolving: policy).moment == instant)
                #expect(try !seen.isStale(now: .epoch))
                instant += .seconds(15 * 60)
            }
        }
    }
}

/// Release `2026b`: New York keeps standard time through 2027.
func abolishDaylightSaving2027(_ rules: ScriptedZoneRules) {
    rules.version = "2026b"
    rules.define(Zones.newYork, offset: Zones.hours(-5), transitions: Array(Zones.newYorkTransitions.prefix(2)))
}
