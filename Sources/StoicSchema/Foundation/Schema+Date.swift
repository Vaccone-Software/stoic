#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif
internal import StoicJSON

/// How a `Date` is spelt on the wire.
public enum DateFormat: Sendable, Hashable, CaseIterable {
    /// An RFC 3339 date-time, the profile of ISO 8601 that JSON APIs use:
    /// `2024-05-01T12:30:00Z`, `2024-05-01T14:30:00.250+02:00`. Fractional
    /// seconds of any length and any offset are read; `t`, `z` and a space
    /// for the `T` are accepted, as RFC 3339 allows. A time without an
    /// offset is refused, since it names no instant. Written in UTC, with
    /// the fewest fractional digits that read back as the same `Date`, so
    /// whole seconds have none and milliseconds have three.
    case iso8601
    /// A number of seconds since 1970-01-01T00:00:00Z, which may have a
    /// fraction: Unix time.
    case epochSeconds
    /// A whole number of milliseconds since 1970-01-01T00:00:00Z, as
    /// JavaScript's `Date.now()` gives.
    case epochMilliseconds
}

extension Schema where Value == Date {
    /// A point in time, spelt as `format` says; RFC 3339 by default.
    ///
    /// Every format covers the years 0000 to 9999 (UTC), the range RFC 3339
    /// can write, so a `Date` decoded in one format can be written in any
    /// other. A date-time that does not exist (February 30th, hour 24) is
    /// `invalid_format` with the reason, not a date the calendar quietly
    /// rolls over. An epoch number outside the range is `out_of_range`.
    ///
    /// A `Date` keeps neither the offset it was written with nor digits
    /// past its own precision (about a tenth of a microsecond today): it is
    /// an instant, written back in UTC.
    public static func date(_ format: DateFormat = .iso8601) -> Schema<Date> {
        switch format {
        case .iso8601: rfc3339
        case .epochSeconds: epochSeconds
        case .epochMilliseconds: epochMilliseconds
        }
    }

    private static let rfc3339Expectation = #"an RFC 3339 date-time, such as "2024-05-01T12:30:00Z""#

    private static var rfc3339: Schema<Date> {
        .formatted(
            name: "Date", format: "date-time", describe: rfc3339Expectation,
            examples: [
                "1970-01-01T00:00:00Z", "2024-02-29T23:59:59.999Z", "0001-01-01T00:00:00Z", "9999-12-31T23:59:59Z",
                "2000-01-01T12:00:00.5+01:00", "2024-05-01T14:30:00.123456-07:30", "1969-12-31T23:59:59.000001Z",
                "2024-05-01t12:00:00z", "1600-03-01 00:00:00+14:00",
            ],
            counterexamples: ["2024-02-30T00:00:00Z", "2024-05-01T12:30:00", "2024-05-01", "yesterday"],
            parse: { RFC3339.parse($0) },
            print: { RFC3339.format($0) })
    }

    /// Seconds from 0000-01-01T00:00:00Z and to 9999-12-31T23:59:59Z.
    private static let firstSecond: Int64 = -62_167_219_200
    private static let lastSecond: Int64 = 253_402_300_799

    private static var epochSeconds: Schema<Date> {
        .transform(
            base: .double(.range(Double(firstSecond)...(Double(lastSecond) + 0.999_999))),
            decode: { seconds throws(TransformFailure) in Date(timeIntervalSince1970: seconds) },
            encode: { date in exactSeconds(of: date) },
            describe: "a number of seconds since 1970-01-01T00:00:00Z", name: "Date",
            examples: [
                Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 1_700_000_000),
                Date(timeIntervalSince1970: -1), Date(timeIntervalSince1970: 1_700_000_000.5),
                Date(timeIntervalSince1970: Double(firstSecond)), Date(timeIntervalSince1970: Double(lastSecond)),
            ])
    }

    private static var epochMilliseconds: Schema<Date> {
        .transform(
            base: .int64(.range((firstSecond * 1000)...(lastSecond * 1000 + 999))),
            decode: { milliseconds throws(TransformFailure) in
                Date(timeIntervalSince1970: Double(milliseconds) / 1000)
            },
            encode: { date in
                let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
                // Out of range or not finite: the decode that `validate` runs
                // reports it; an Int64 cannot hold every Double.
                return Int64(exactly: milliseconds) ?? (milliseconds < 0 ? .min : .max)
            },
            describe: "a whole number of milliseconds since 1970-01-01T00:00:00Z", name: "Date",
            examples: [
                Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 1_700_000_000.123),
                Date(timeIntervalSince1970: -0.001), Date(timeIntervalSince1970: Double(firstSecond)),
                Date(timeIntervalSince1970: Double(lastSecond) + 0.999),
            ])
    }

    /// The seconds since 1970 that `Date(timeIntervalSince1970:)` turns back
    /// into exactly `date`. A `Date` counts from 2001, so the obvious sum
    /// can be one unit in the last place away from a number that reads back
    /// the same.
    private static func exactSeconds(of date: Date) -> Double {
        let sum = date.timeIntervalSince1970
        for candidate in [sum, sum.nextUp, sum.nextDown] where Date(timeIntervalSince1970: candidate) == date {
            return candidate
        }
        return sum
    }
}

extension Date: Schematic {
    /// RFC 3339; see ``Schema/date(_:)`` for the epoch formats.
    public static var schema: Schema<Date> { .date() }
}

/// RFC 3339 date-times, read and written without a formatter.
///
/// A formatter is locale and calendar machinery, and lenient where a wire
/// format must not be (it rolls February 30th over into March). This is the
/// grammar of RFC 3339 section 5.6, with the day checked against the month,
/// read into whole seconds and a fraction, and turned into a `Date` with one
/// rounding.
enum RFC3339 {
    /// Seconds from 1970 to 2001, the epoch `Date` counts from.
    private static let referenceOffset: Int64 = 978_307_200
    private static let firstSecond: Int64 = -62_167_219_200
    private static let lastSecond: Int64 = 253_402_300_799
    private static let shape = "the form YYYY-MM-DDThh:mm:ss with an offset such as `Z` or `+02:00`"

    static func parse(_ text: String) -> Result<Date, FormatFailure> {
        let bytes = Array(text.utf8)
        var index = 0

        func digits(_ count: Int) -> Int? {
            guard index + count <= bytes.count else { return nil }
            var value = 0
            for offset in 0..<count {
                let byte = bytes[index + offset]
                guard byte >= 0x30 && byte <= 0x39 else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            index += count
            return value
        }
        func expect(_ characters: String) -> Bool {
            guard index < bytes.count, characters.utf8.contains(bytes[index]) else { return false }
            index += 1
            return true
        }
        let malformed = Result<Date, FormatFailure>.failure(FormatFailure("it is not in " + shape))

        guard let year = digits(4), expect("-"), let month = digits(2), expect("-"), let day = digits(2) else {
            return malformed
        }
        if index == bytes.count {
            return .failure(FormatFailure("it is a date without a time; write a time and an offset, such as `T00:00:00Z`"))
        }
        guard expect("Tt "), let hour = digits(2), expect(":"), let minute = digits(2) else { return malformed }
        guard expect(":"), let second = digits(2) else {
            return .failure(FormatFailure("it has no seconds; RFC 3339 needs `hh:mm:ss`"))
        }
        var fraction = 0.0
        if expect(".") {
            let start = index
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1 }
            guard index > start else { return .failure(FormatFailure("a `.` must be followed by digits")) }
            fraction = Double("0." + String(decoding: bytes[start..<index], as: UTF8.self)) ?? 0
        }
        var offsetSeconds = 0
        if expect("Zz") {
            offsetSeconds = 0
        } else if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
            let negative = bytes[index] == UInt8(ascii: "-")
            index += 1
            guard let offsetHour = digits(2) else { return malformed }
            _ = expect(":")
            guard let offsetMinute = digits(2) else { return malformed }
            guard offsetHour <= 23, offsetMinute <= 59 else {
                return .failure(FormatFailure("the offset \(offsetHour):\(offsetMinute) is not a time zone offset"))
            }
            offsetSeconds = (offsetHour * 3600 + offsetMinute * 60) * (negative ? -1 : 1)
        } else if index == bytes.count {
            return .failure(
                FormatFailure("it has no time zone offset, so it names no instant; end it with `Z` for UTC or an offset such as `+02:00`"))
        } else {
            return malformed
        }
        guard index == bytes.count else { return malformed }

        guard (1...12).contains(month) else { return .failure(FormatFailure("there is no month \(month)")) }
        let length = daysIn(month: month, year: year)
        guard (1...length).contains(day) else {
            return .failure(FormatFailure("month \(month) of \(year) has \(length) days, not \(day)"))
        }
        guard hour <= 23 else { return .failure(FormatFailure("there is no hour \(hour)")) }
        guard minute <= 59 else { return .failure(FormatFailure("there is no minute \(minute)")) }
        guard second <= 59 else {
            return .failure(
                FormatFailure(second == 60 ? "it is a leap second, which a `Date` cannot hold" : "there is no second \(second)"))
        }

        let days = daysFromCivil(year: Int64(year), month: Int64(month), day: Int64(day))
        let seconds = days * 86_400 + Int64(hour * 3600 + minute * 60 + second) - Int64(offsetSeconds)
        guard seconds >= firstSecond, seconds <= lastSecond else {
            return .failure(FormatFailure("in UTC it falls outside the years 0000 to 9999"))
        }
        return .success(Date(timeIntervalSinceReferenceDate: Double(seconds - referenceOffset) + fraction))
    }

    /// `date` in UTC with the fewest fractional digits that read back as
    /// exactly `date`, or `nil` if it is outside the years 0000 to 9999.
    static func format(_ date: Date) -> String? {
        let interval = date.timeIntervalSinceReferenceDate
        guard interval.isFinite else { return nil }
        let whole = interval.rounded(.down)
        let fraction = interval - whole
        guard let wholeSeconds = Int64(exactly: whole) else { return nil }
        let seconds = wholeSeconds + referenceOffset
        guard seconds >= firstSecond, seconds <= lastSecond else { return nil }
        let stem = civil(seconds)
        if fraction == 0 { return stem + "Z" }
        var scale = 1.0
        for count in 1...9 {
            scale *= 10
            let scaled = (fraction * scale).rounded()
            guard scaled < scale, let digits = Int(exactly: scaled) else { continue }
            var text = String(digits)
            text = String(repeating: "0", count: count - text.count) + text
            let candidate = stem + "." + text + "Z"
            if case .success(let back) = parse(candidate), back == date { return candidate }
        }
        // Closer than nine digits can say; the nearest nanosecond is as
        // good as any spelling gets.
        let nanoseconds = min((fraction * 1e9).rounded(), 999_999_999)
        let text = String(Int(nanoseconds))
        return stem + "." + String(repeating: "0", count: 9 - text.count) + text + "Z"
    }

    /// `YYYY-MM-DDThh:mm:ss` for seconds since 1970, in UTC.
    private static func civil(_ seconds: Int64) -> String {
        var days = seconds / 86_400
        var rest = seconds % 86_400
        if rest < 0 {
            rest += 86_400
            days -= 1
        }
        let (year, month, day) = civilFromDays(days)
        func pad(_ value: Int64, _ width: Int) -> String {
            let text = String(value)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))T\(pad(rest / 3600, 2)):\(pad(rest / 60 % 60, 2)):\(pad(rest % 60, 2))"
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// Days since 1970-01-01 of a date in the proleptic Gregorian calendar
    /// (Howard Hinnant's algorithm).
    private static func daysFromCivil(year: Int64, month: Int64, day: Int64) -> Int64 {
        let shifted = month <= 2 ? year - 1 : year
        let era = (shifted >= 0 ? shifted : shifted - 399) / 400
        let yearOfEra = shifted - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func civilFromDays(_ days: Int64) -> (year: Int64, month: Int64, day: Int64) {
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }
}
