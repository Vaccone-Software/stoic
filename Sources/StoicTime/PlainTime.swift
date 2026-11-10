internal import Stoic

/// A time of day on a wall clock, with no date and no zone: 09:00, the time
/// an event starts wherever it is held.
///
///     let doorsOpen = try PlainTime(9, 0)
///
/// From 00:00 up to, not including, 24:00, to the nanosecond. A time that
/// does not exist (hour 24, minute 60) is ``TimeError/invalid(_:)`` at
/// construction. There are no leap seconds: Unix time and the zone rules
/// count none. Its text is ISO 8601's, as short as the value allows:
/// `09:00`, `09:00:30`, `09:00:30.5`.
public struct PlainTime: Sendable, Hashable, Comparable {
    static let nanosecondsPerDay: Int64 = 86_400_000_000_000

    /// Nanoseconds since midnight, below a day.
    let nanosecondOfDay: Int64

    /// `hour`:`minute`:`second` and `nanosecond`, or ``TimeError/invalid(_:)``
    /// if there is no such time.
    public init(_ hour: Int, _ minute: Int, _ second: Int = 0, nanosecond: Int = 0) throws(TimeError) {
        guard (0...23).contains(hour) else {
            throw .invalid(hour == 24 ? "the hour 24 is the next day's 00" : "there is no hour \(hour)")
        }
        guard (0...59).contains(minute) else { throw .invalid("there is no minute \(minute)") }
        guard (0...59).contains(second) else {
            throw .invalid(second == 60 ? "a leap second, which the zone rules do not count" : "there is no second \(second)")
        }
        guard (0..<1_000_000_000).contains(nanosecond) else { throw .invalid("\(nanosecond) is not a nanosecond of a second") }
        nanosecondOfDay = (Int64(hour) * 3600 + Int64(minute) * 60 + Int64(second)) * 1_000_000_000 + Int64(nanosecond)
    }

    /// The time `nanoseconds` after midnight, below a day.
    init(nanosecondOfDay nanoseconds: Int64) {
        nanosecondOfDay = nanoseconds
    }

    /// 00:00.
    public static let midnight = PlainTime(nanosecondOfDay: 0)

    /// 12:00.
    public static let noon = PlainTime(nanosecondOfDay: 43_200_000_000_000)

    /// 0 to 23.
    public var hour: Int { Int(nanosecondOfDay / 3_600_000_000_000) }
    /// 0 to 59.
    public var minute: Int { Int(nanosecondOfDay / 60_000_000_000 % 60) }
    /// 0 to 59.
    public var second: Int { Int(nanosecondOfDay / 1_000_000_000 % 60) }
    /// 0 to 999,999,999.
    public var nanosecond: Int { Int(nanosecondOfDay % 1_000_000_000) }

    public static func < (lhs: PlainTime, rhs: PlainTime) -> Bool {
        lhs.nanosecondOfDay < rhs.nanosecondOfDay
    }
}

extension PlainTime: CustomStringConvertible {
    /// `09:00` when the seconds are zero, else `09:00:30`, with a fraction
    /// when there is one: `09:00:30.5`.
    public var description: String {
        var text = "\(TimeTextWriter.padded(hour, 2)):\(TimeTextWriter.padded(minute, 2))"
        if second != 0 || nanosecond != 0 { text += ":" + secondsText }
        return text
    }

    /// `ss` and the fraction, if any: what RFC 3339 writes after the minutes.
    var secondsText: String {
        TimeTextWriter.padded(second, 2) + TimeTextWriter.fraction(attoseconds: Int64(nanosecond) * 1_000_000_000)
    }

    /// Reads an ISO 8601 time of day: `hh:mm`, `hh:mm:ss`, or with a
    /// fraction of up to nine digits.
    ///
    /// - Throws: ``TimeError/invalid(_:)`` with the reason, including for a
    ///   time with an offset (a time with an offset is not a time of day
    ///   anywhere).
    public init(parsing text: String) throws(TimeError) {
        switch Self.parse(text) {
        case .success(let time): self = time
        case .failure(let failure): throw .invalid("\"\(text)\" is not a time of day: \(failure.message)")
        }
    }

    static func parse(_ text: String) -> Result<PlainTime, TimeTextFailure> {
        var scanner = TimeTextScanner(text)
        switch scanner.time(requireSeconds: false, fractionDigits: 9) {
        case .success(let time):
            guard scanner.isAtEnd else {
                return .failure(TimeTextFailure("it goes on after the time; a time of day has no offset or zone"))
            }
            return .success(PlainTime(time))
        case .failure(let failure):
            return .failure(failure)
        }
    }

    /// The time a scanner read, already checked.
    init(_ time: (hour: Int, minute: Int, second: Int, attoseconds: Int64)) {
        nanosecondOfDay = (Int64(time.hour) * 3600 + Int64(time.minute) * 60 + Int64(time.second)) * 1_000_000_000
            + time.attoseconds / 1_000_000_000
    }
}

extension PlainTime: Codable {
    /// Reads the time's text, `09:00` or `09:00:30.5`.
    public init(from decoder: any Decoder) throws {
        self = try decodeText(from: decoder, kind: "a time of day", parse: Self.parse)
    }

    /// Writes the time's text, `09:00` or `09:00:30.5`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// A date and a time of day, with no zone: when, on a wall calendar and a
/// wall clock, wherever that is.
///
/// What an organiser means by "9:00 on 14 March". It names no instant until
/// a zone is said (``ZonedDateTime``), so it is never stored for something
/// that happened. Its text is `2027-03-14T09:00`.
public struct PlainDateTime: Sendable, Hashable, Comparable {
    public var date: PlainDate
    public var time: PlainTime

    public init(_ date: PlainDate, _ time: PlainTime) {
        self.date = date
        self.time = time
    }

    public static func < (lhs: PlainDateTime, rhs: PlainDateTime) -> Bool {
        (lhs.date, lhs.time.nanosecondOfDay) < (rhs.date, rhs.time.nanosecondOfDay)
    }

    /// The local date and time read as if it were UTC: the instant a zone
    /// with offset zero would give it. Zone arithmetic subtracts an offset
    /// from it.
    var asIfUTC: Duration {
        .seconds(Int64(date.daysSinceEpoch) * 86_400) + .nanoseconds(time.nanosecondOfDay)
    }

    /// The local date and time whose ``asIfUTC`` is `duration`, to the
    /// nanosecond below it, or ``TimeError/outOfRange(_:)``.
    init(asIfUTC duration: Duration) throws(TimeError) {
        let (nanoseconds, _) = floorDivision(duration.attoseconds, by: 1_000_000_000)
        let (days, nanosecondOfDay) = floorDivision(nanoseconds, by: Int128(PlainTime.nanosecondsPerDay))
        guard let day = Int(exactly: days) else { throw .outOfRange("the date is outside the years 0001–9999") }
        self.init(try PlainDate(daysSinceEpoch: day), PlainTime(nanosecondOfDay: Int64(nanosecondOfDay)))
    }
}

extension PlainDateTime: CustomStringConvertible {
    /// `2027-03-14T09:00`, the time as short as it allows.
    public var description: String {
        "\(date)T\(time)"
    }

    /// Reads an ISO 8601 local date-time: `2027-03-14T09:00`,
    /// `2027-03-14T09:00:30.5`.
    ///
    /// - Throws: ``TimeError/invalid(_:)`` with the reason, including for
    ///   a moment's text (with `Z` or an offset), which names an instant, not
    ///   a wall-clock reading.
    public init(parsing text: String) throws(TimeError) {
        switch Self.parse(text) {
        case .success(let value): self = value
        case .failure(let failure): throw .invalid("\"\(text)\" is not a date and time: \(failure.message)")
        }
    }

    static func parse(_ text: String) -> Result<PlainDateTime, TimeTextFailure> {
        var scanner = TimeTextScanner(text)
        let date: PlainDate
        switch scanner.date() {
        case .success(let value): date = PlainDate(unchecked: value.year, value.month, value.day)
        case .failure(let failure): return .failure(failure)
        }
        if scanner.isAtEnd { return .failure(TimeTextFailure("it is a date without a time; write the time after a `T`")) }
        guard scanner.take("Tt") != nil else {
            return .failure(TimeTextFailure("the date and the time must be separated by `T`"))
        }
        switch scanner.time(requireSeconds: false, fractionDigits: 9) {
        case .success(let time):
            guard scanner.isAtEnd else {
                return .failure(
                    TimeTextFailure("it goes on after the time; with an offset it is a moment, and with a zone a zoned date-time"))
            }
            return .success(PlainDateTime(date, PlainTime(time)))
        case .failure(let failure):
            return .failure(failure)
        }
    }
}

extension PlainDateTime: Codable {
    /// Reads the date-time's text, `2027-03-14T09:00`.
    public init(from decoder: any Decoder) throws {
        self = try decodeText(from: decoder, kind: "a date and time", parse: Self.parse)
    }

    /// Writes the date-time's text, `2027-03-14T09:00`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
