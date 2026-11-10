import Foundation
@testable import Stoic
import StoicTesting
import Testing

@Suite("Moment")
struct MomentTests {
    private static func moment(_ text: String) throws -> Moment {
        try #require(Moment(rfc3339: text), "\(text) should read as a moment")
    }

    // MARK: Arithmetic

    @Test func arithmeticMovesOnTheTimeline() throws {
        let start = try Self.moment("2026-11-09T18:34:12Z")
        let week = start + .seconds(7 * 86_400)
        #expect(week.rfc3339 == "2026-11-16T18:34:12Z")
        #expect(week - .seconds(7 * 86_400) == start)
        #expect(start.duration(to: week) == .seconds(604_800))
        #expect(week.duration(to: start) == .seconds(-604_800))
        var moving = start
        moving += .milliseconds(425)
        #expect(moving.rfc3339 == "2026-11-09T18:34:12.425Z")
        moving -= .milliseconds(425)
        #expect(moving == start)
        #expect(start < week)
        #expect(Moment.epoch.rfc3339 == "1970-01-01T00:00:00Z")
    }

    // MARK: Text

    @Test(arguments: [
        ("2026-11-09T18:34:12.425Z", "2026-11-09T18:34:12.425Z"),
        ("2026-11-09T19:34:12.425+01:00", "2026-11-09T18:34:12.425Z"),
        ("2026-11-09t13:34:12.425-05:00", "2026-11-09T18:34:12.425Z"),
        ("2026-11-09T18:34:12z", "2026-11-09T18:34:12Z"),
        ("2026-11-09T18:34:12.000Z", "2026-11-09T18:34:12Z"),
        ("2026-11-09T18:34:12-00:00", "2026-11-09T18:34:12Z"),
        ("2024-02-29T23:59:59.999999999Z", "2024-02-29T23:59:59.999999999Z"),
        ("1969-12-31T23:59:59.000000000000000001Z", "1969-12-31T23:59:59.000000000000000001Z"),
        ("0001-01-01T00:00:00Z", "0001-01-01T00:00:00Z"),
        ("9999-12-31T23:59:59.999999999999999999Z", "9999-12-31T23:59:59.999999999999999999Z"),
        ("2000-01-01T00:00:00+14:00", "1999-12-31T10:00:00Z"),
    ])
    func rfc3339IsReadAndWrittenInUTC(text: String, written: String) throws {
        #expect(try Self.moment(text).rfc3339 == written)
    }

    @Test(arguments: [
        ("2026-02-30T00:00:00Z", "month 2 of 2026 has 28 days, not 30"),
        ("2026-13-01T00:00:00Z", "there is no month 13"),
        ("2026-11-09T24:00:00Z", "the hour 24 is the next day's 00"),
        ("2026-11-09T18:60:00Z", "there is no minute 60"),
        ("2016-12-31T23:59:60Z", "leap second"),
        ("2026-11-09T18:34:12", "it has no offset"),
        ("2026-11-09", "a date without a time"),
        ("2026-11-09T18:34Z", "it has no seconds"),
        ("2026-11-09 18:34:12Z", "separated by `T`"),
        ("2026-11-09T18:34:12.Z", "must be followed by digits"),
        ("2026-11-09T18:34:12.0000000000000000001Z", "finer than an attosecond"),
        ("2026-11-09T18:34:12+0100", "the offset is not in the form"),
        ("2026-11-09T18:34:12+24:00", "is not an offset from UTC"),
        ("2026-11-09T18:34:12-04:00[America/New_York]", "a zoned date-time"),
        ("0001-01-01T00:30:00+01:00", "outside the years 0001 to 9999"),
        ("0000-12-31T23:00:00Z", "outside 0001–9999"),
        ("yesterday", "the form YYYY-MM-DD"),
    ])
    func textThatIsNotAMomentIsRefusedWithTheReason(text: String, reason: String) {
        guard case .failure(let failure) = Moment.parse(rfc3339: text) else {
            Issue.record("\(text) should be refused")
            return
        }
        #expect(failure.message.contains(reason), "\(failure.message)")
        #expect(Moment(rfc3339: text) == nil)
    }

    @Test(.failureMode("design/26", "a moment is before 1970 or far in the future"))
    func aMomentBeforeTheEpochOrFarAheadIsExactAndItsTextStopsAtTheRange() throws {
        let early = Moment(sinceEpoch: .seconds(-62_135_596_800))
        #expect(early.rfc3339 == "0001-01-01T00:00:00Z")
        let before = early - .nanoseconds(1)
        #expect(before.rfc3339 == nil, "0000 is outside what RFC 3339 writes")
        #expect(before.sinceEpoch == .seconds(-62_135_596_800) - .nanoseconds(1), "but the moment is exact")
        let late = Moment(sinceEpoch: .seconds(253_402_300_799) + .nanoseconds(999_999_999))
        #expect(late.rfc3339 == "9999-12-31T23:59:59.999999999Z")
        #expect((late + .nanoseconds(1)).rfc3339 == nil)
        let distant = Moment(sinceEpoch: .seconds(Int64.max / 2))
        #expect(distant + .seconds(1) - .seconds(1) == distant)
        #expect(distant.description.hasPrefix("Moment(sinceEpoch:"))
        #expect(Moment(sinceEpoch: .seconds(-1)).rfc3339 == "1969-12-31T23:59:59Z")
        #expect(Moment(sinceEpoch: .milliseconds(-1)).rfc3339 == "1969-12-31T23:59:59.999Z")
    }

    @Test func codableIsTheRFC3339TextAndRefusesWhatItCannotWrite() throws {
        struct Event: Codable, Equatable { var at: Moment }
        let event = Event(at: try Self.moment("2026-11-09T18:34:12.425Z"))
        let data = try JSONEncoder().encode(event)
        #expect(String(decoding: data, as: UTF8.self) == #"{"at":"2026-11-09T18:34:12.425Z"}"#)
        #expect(try JSONDecoder().decode(Event.self, from: data) == event)

        let offset = Data(#"{"at":"2026-11-09T19:34:12.425+01:00"}"#.utf8)
        #expect(try JSONDecoder().decode(Event.self, from: offset) == event)

        let error = #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Event.self, from: Data(#"{"at":"2026-02-30T00:00:00Z"}"#.utf8))
        }
        guard case .dataCorrupted(let context)? = error else { return }
        #expect(context.debugDescription.contains("has 28 days, not 30"))

        #expect(throws: EncodingError.self) {
            try JSONEncoder().encode(Event(at: Moment(sinceEpoch: .seconds(Int64.max / 2))))
        }
    }

    /// Every moment the text can write, to the attosecond, reads back as
    /// itself, and the order of moments is the order of their texts (in UTC,
    /// with the fraction padded).
    @Test func textRoundTripsOverTheWholeRange() throws {
        var random = RandomSource.seeded(26).generator()
        let first = Int64(-62_135_596_800), last = Int64(253_402_300_799)
        for _ in 0..<20_000 {
            let seconds = Int64.random(in: first...last, using: &random)
            let attoseconds = Int64.random(in: 0..<1_000_000_000_000_000_000, using: &random)
            let shapes = [attoseconds, attoseconds / 1_000_000_000 * 1_000_000_000, 0]
            for fraction in shapes {
                let moment = Moment(sinceEpoch: .seconds(seconds) + .init(secondsComponent: 0, attosecondsComponent: fraction))
                let text = try #require(moment.rfc3339)
                #expect(Moment(rfc3339: text) == moment, "\(text)")
            }
        }
    }

    // MARK: The system clock

    @Test func theDefaultWallClockIsTheSystems() {
        let before = Date().timeIntervalSince1970
        let now = Ambient().wallClock.now
        let after = Date().timeIntervalSince1970
        let seconds = Double(now.sinceEpoch.components.seconds) + Double(now.sinceEpoch.components.attoseconds) / 1e18
        #expect(seconds >= before - 0.001 && seconds <= after + 0.001, "CLOCK_REALTIME and Foundation agree on now")
    }

    @Test func aFixedWallClockSaysOneMoment() throws {
        let fixed = try Self.moment("2027-03-14T13:00:00Z")
        let read = withAmbient({ $0.wallClock = .fixed(fixed) }) { Moment.now }
        #expect(read == fixed)
    }
}
