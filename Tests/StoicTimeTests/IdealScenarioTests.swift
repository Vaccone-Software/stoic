import Foundation
import Stoic
import StoicTesting
import StoicTime
import Testing

/// design/26's ideal scenario, as written there: a volunteering app. An
/// event is planned for 9:00 on 14 March in New York; volunteers check in
/// when they arrive; a minor needs a parent's waiver; the waiver link
/// expires in seven days; an OS update changes New York's rules.
@Suite("Time: the ideal scenario")
struct IdealScenarioTests {
    struct Event: Codable, Equatable {
        var name: String
        var start: ZonedDateTime
    }

    struct Commitment: Codable, Equatable {
        var checkedInAt: Moment?
    }

    struct Waiver: Codable, Equatable {
        var expiresAt: Moment
    }

    struct Profile: Codable, Equatable {
        var dateOfBirth: PlainDate
    }

    @Test func theVolunteeringApp() async throws {
        let rules = Zones.rules()
        // The test begins on the morning of the event, New York time.
        let clock = TestClock(wallClockStart: Zones.moment("2027-03-14T12:00:00Z"))
        try await onTestTime(rules, clock: clock) {
            // A planned moment: local time and zone are the truth; the
            // instant is derived. 9:00 on the day the clocks change is EDT.
            let start = try ZonedDateTime(PlainDate(2027, 3, 14), PlainTime(9, 0), in: "America/New_York")
            let other = try ZonedDateTime(PlainDate(2027, 3, 14), PlainTime(18, 0), in: Zones.kolkata)
            var events = [Event(name: "park clean-up", start: start), Event(name: "food bank", start: other)]
            events.sort { $0.start.moment < $1.start.moment }  // sorts like UTC
            #expect(events.map(\.name) == ["food bank", "park clean-up"], "18:00 IST is 12:30Z, before 13:00Z")
            #expect("\(start.local.time) \(start.zone)" == "09:00 America/New_York")  // always 09:00, New York time

            // Something that happened: a moment, from the injected wall clock.
            await clock.advance(by: .seconds(55 * 60))
            var commitment = Commitment()
            commitment.checkedInAt = Moment.now
            #expect(commitment.checkedInAt == Zones.moment("2027-03-14T12:55:00Z"))
            #expect(try commitment.checkedInAt?.in(start.zone).local.time == PlainTime(8, 55), "five minutes early, local time")

            // A day: no zone, no instant.
            let profile = Profile(dateOfBirth: try PlainDate(2009, 3, 15))
            let isMinor = profile.dateOfBirth.age(on: try PlainDate.today(in: start.zone)) < 18
            #expect(isMinor, "seventeen until tomorrow")

            // An expiry: seven days of elapsed time, on the timeline.
            let waiver = Waiver(expiresAt: Moment.now + .seconds(7 * 86_400))
            #expect(waiver.expiresAt == Zones.moment("2027-03-21T12:55:00Z"))

            // Everything is stored as text that reads back as itself.
            let stored = try JSONEncoder().encode(events)
            #expect(String(decoding: stored, as: UTF8.self).contains(#""2027-03-14T09:00:00-04:00[America\/New_York]""#))
            var upcoming = try JSONDecoder().decode([Event].self, from: stored)
            #expect(upcoming == events)

            // A November event, and then an OS update that ends daylight
            // saving in New York from June: one sweep, future values only.
            upcoming.append(Event(name: "harvest", start: try ZonedDateTime(PlainDate(2027, 7, 4), PlainTime(9, 0), in: Zones.newYork)))
            rules.version = "2026b"
            rules.define(
                Zones.newYork, offset: Zones.hours(-5),
                transitions: [
                    .init(at: Zones.moment("2027-03-14T07:00:00Z"), offset: Zones.hours(-4)),
                    .init(at: Zones.moment("2027-06-01T06:00:00Z"), offset: Zones.hours(-5)),
                ])
            await clock.advance(by: .seconds(3600))  // the 9:00 event is now past
            for index in upcoming.indices where try upcoming[index].start.isStale() {
                upcoming[index].start = try upcoming[index].start.refreshed()  // same 9:00, new instant
            }
            #expect(upcoming[0].start == events[0].start && upcoming[1].start == events[1].start, "past values are final")
            #expect(try upcoming[2].start.local.time == PlainTime(9, 0))
            #expect(upcoming[2].start.moment == Zones.moment("2027-07-04T14:00:00Z"), "09:00 EST now, not EDT")
        }
    }
}
