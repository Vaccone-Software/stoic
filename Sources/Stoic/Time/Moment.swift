/// A point on the world's timeline: when something happened, the same
/// everywhere.
///
///     commitment.checkedInAt = Moment.now
///     waiver.expiresAt = Moment.now + .seconds(7 * 86_400)
///
/// A moment is a `Duration` since 1970-01-01T00:00:00Z, Unix time: it counts
/// no leap seconds, and it has no zone, because an instant does not depend
/// on where it is seen from. Its text is RFC 3339 in UTC
/// (`2026-11-09T18:34:12.425Z`), which is also how it encodes.
///
/// It answers "when did it happen?", and only that. How long something took
/// is measured on a monotonic clock (`AnyClock`), never by subtracting two
/// moments: the wall clock a moment is read from can be set by a person or
/// corrected by the network, and jumps. A monotonic instant, in turn, means
/// nothing after a reboot, so it is never stored. There is no conversion
/// between `AnyClock.Instant` and `Moment`, on purpose. Which day it is, and
/// what a clock on the wall says, are questions about a place: `StoicTime`
/// answers them (design/26).
///
/// Any `Duration` is a moment, so one before 1970 or millions of years ahead
/// is represented exactly, to the attosecond. Its text covers the years
/// 0001 to 9999, which is what RFC 3339 can write; encoding one outside
/// them throws.
public struct Moment: Sendable, Hashable, Comparable {
    /// The time since 1970-01-01T00:00:00Z; negative before it.
    public let sinceEpoch: Duration

    public init(sinceEpoch: Duration) {
        self.sinceEpoch = sinceEpoch
    }

    /// 1970-01-01T00:00:00Z.
    public static let epoch = Moment(sinceEpoch: .zero)

    /// The time now, from the ambient wall clock (``Ambient/wallClock``).
    ///
    /// In an app, the system's real-time clock. Under a test's ambient
    /// context, the test clock's: a fixed start that moves only when the
    /// test moves it, so a test that reads the time reads the same time on
    /// every run.
    public static var now: Moment { Ambient.current.wallClock.now }

    /// The moment `duration` later. Traps on overflow, as `Duration` does.
    public static func + (moment: Moment, duration: Duration) -> Moment {
        Moment(sinceEpoch: moment.sinceEpoch + duration)
    }

    /// The moment `duration` earlier. Traps on overflow, as `Duration` does.
    public static func - (moment: Moment, duration: Duration) -> Moment {
        Moment(sinceEpoch: moment.sinceEpoch - duration)
    }

    public static func += (moment: inout Moment, duration: Duration) {
        moment = moment + duration
    }

    public static func -= (moment: inout Moment, duration: Duration) {
        moment = moment - duration
    }

    /// The time from this moment to `other`: positive when `other` is later.
    ///
    /// The difference of two readings of a wall clock, which may have been
    /// set in between: for an elapsed time that matters, measure on a
    /// monotonic clock instead.
    public func duration(to other: Moment) -> Duration {
        other.sinceEpoch - sinceEpoch
    }

    public static func < (lhs: Moment, rhs: Moment) -> Bool {
        lhs.sinceEpoch < rhs.sinceEpoch
    }
}

extension Moment: CustomStringConvertible {
    /// The moment's RFC 3339 text, or its duration since the epoch when it
    /// is outside the years 0001 to 9999.
    public var description: String {
        rfc3339 ?? "Moment(sinceEpoch: \(sinceEpoch))"
    }
}

// MARK: - RFC 3339

extension Moment {
    /// The attoseconds in a second.
    private static let attosecondsPerSecond: Int128 = 1_000_000_000_000_000_000

    /// The first and last seconds RFC 3339 can write, since the epoch:
    /// 0001-01-01T00:00:00Z and 9999-12-31T23:59:59Z.
    private static let firstSecond: Int128 = Int128(CivilCalendar.firstDay) * 86_400
    private static let lastSecond: Int128 = Int128(CivilCalendar.lastDay) * 86_400 + 86_399

    /// Reads an RFC 3339 date-time: `2026-11-09T18:34:12.425Z`,
    /// `2026-11-09T19:34:12+01:00`.
    ///
    /// The grammar of RFC 3339 section 5.6, strictly: seconds are required,
    /// the offset is `Z` or `±hh:mm`, and `t` and `z` may be lower case. A
    /// date that does not exist (30 February), a leap second (Unix time has
    /// none), and a fraction finer than an attosecond are refused, never
    /// rolled over or rounded. `nil` if `text` is not one; ``Moment``'s
    /// `Decodable` conformance says why.
    public init?(rfc3339 text: String) {
        guard case .success(let moment) = Self.parse(rfc3339: text) else { return nil }
        self = moment
    }

    /// The moment in RFC 3339, in UTC, with the fewest fractional digits
    /// that say it exactly: `2026-11-09T18:34:12Z`,
    /// `2026-11-09T18:34:12.425Z`. `nil` outside the years 0001 to 9999.
    public var rfc3339: String? {
        let (seconds, attoseconds) = floorDivision(sinceEpoch.attoseconds, by: Self.attosecondsPerSecond)
        guard seconds >= Self.firstSecond, seconds <= Self.lastSecond else { return nil }
        let (days, secondOfDay) = floorDivision(seconds, by: 86_400)
        let (year, month, day) = CivilCalendar.date(daysSinceEpoch: Int(days))
        let second = Int(secondOfDay)
        return TimeTextWriter.date(year: year, month: month, day: day)
            + "T\(TimeTextWriter.padded(second / 3600, 2)):\(TimeTextWriter.padded(second / 60 % 60, 2)):\(TimeTextWriter.padded(second % 60, 2))"
            + TimeTextWriter.fraction(attoseconds: Int64(attoseconds)) + "Z"
    }

    /// RFC 3339 text read into a moment, or why it is not one.
    package static func parse(rfc3339 text: String) -> Result<Moment, TimeTextFailure> {
        var scanner = TimeTextScanner(text)
        let date: (year: Int, month: Int, day: Int)
        switch scanner.date() {
        case .success(let value): date = value
        case .failure(let failure): return .failure(failure)
        }
        if scanner.isAtEnd {
            return .failure(TimeTextFailure("it is a date without a time; a moment needs a time and an offset, such as `T00:00:00Z`"))
        }
        guard scanner.take("Tt") != nil else {
            return .failure(TimeTextFailure("the date and the time must be separated by `T`"))
        }
        let time: (hour: Int, minute: Int, second: Int, attoseconds: Int64)
        switch scanner.time(requireSeconds: true, fractionDigits: 18) {
        case .success(let value): time = value
        case .failure(let failure): return .failure(failure)
        }
        let offset: Int
        switch scanner.offset(allowZ: true, allowSeconds: false) {
        case .success(let value): offset = value
        case .failure(let failure): return .failure(failure)
        }
        guard scanner.isAtEnd else {
            return .failure(TimeTextFailure("it goes on after the offset; a zone in brackets is a zoned date-time, not a moment"))
        }
        let days = Int128(CivilCalendar.daysSinceEpoch(year: date.year, month: date.month, day: date.day))
        let seconds = days * 86_400 + Int128(time.hour * 3600 + time.minute * 60 + time.second) - Int128(offset)
        guard seconds >= firstSecond, seconds <= lastSecond else {
            return .failure(TimeTextFailure("in UTC it falls outside the years 0001 to 9999"))
        }
        return .success(Moment(sinceEpoch: Duration(attoseconds: seconds * attosecondsPerSecond + Int128(time.attoseconds))))
    }
}

extension Moment: Codable {
    /// Reads the moment's RFC 3339 text (see ``init(rfc3339:)``).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        switch Self.parse(rfc3339: text) {
        case .success(let moment):
            self = moment
        case .failure(let failure):
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "\"\(text)\" is not an RFC 3339 date-time: \(failure.message)")
        }
    }

    /// Writes the moment's RFC 3339 text in UTC (see ``rfc3339``), or throws
    /// `EncodingError.invalidValue` outside the years 0001 to 9999.
    public func encode(to encoder: any Encoder) throws {
        guard let text = rfc3339 else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "\(self) is outside the years 0001 to 9999, which RFC 3339 can write"))
        }
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}
