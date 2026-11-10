/// Why a text is not the time it was read as: a clause about the text, such
/// as `there is no month 13`.
package struct TimeTextFailure: Error, Sendable, Hashable {
    package let message: String

    package init(_ message: String) {
        self.message = message
    }
}

/// A cursor over the ASCII of a date, time or offset, reading the pieces
/// RFC 3339, RFC 9557 and ISO 8601 share.
///
/// Package-wide, not public: ``Moment``'s text and every text form of
/// `StoicTime` are read with it, so a date is checked against its month,
/// a fraction against its precision and an offset against its range the
/// same way in each. No formatter, locale or calendar is involved: a wire
/// format is a grammar, and a formatter is lenient where a grammar must not
/// be (it rolls 30 February over into March).
package struct TimeTextScanner {
    private let bytes: [UInt8]
    package private(set) var index = 0

    package init(_ text: String) {
        bytes = Array(text.utf8)
    }

    package var isAtEnd: Bool { index == bytes.count }

    /// The next byte, without taking it.
    package var next: UInt8? { index < bytes.count ? bytes[index] : nil }

    /// Takes the next byte if it is one of `choices`.
    package mutating func take(_ choices: String) -> UInt8? {
        guard let byte = next, choices.utf8.contains(byte) else { return nil }
        index += 1
        return byte
    }

    /// Takes exactly `count` ASCII digits as a number.
    package mutating func digits(_ count: Int) -> Int? {
        guard index + count <= bytes.count else { return nil }
        var value = 0
        for offset in 0..<count {
            let byte = bytes[index + offset]
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            value = value * 10 + Int(byte - 0x30)
        }
        index += count
        return value
    }

    /// Takes one or more digits, at most `limit` of them, as a number.
    package mutating func number(upTo limit: Int) -> Int? {
        var value = 0
        var count = 0
        while count < limit, let byte = next, byte >= 0x30, byte <= 0x39 {
            value = value * 10 + Int(byte - 0x30)
            index += 1
            count += 1
        }
        return count == 0 ? nil : value
    }

    /// The rest of the text from the cursor, taken whole.
    package mutating func rest() -> String {
        defer { index = bytes.count }
        return String(decoding: bytes[index...], as: UTF8.self)
    }

    /// Takes bytes up to (not including) `terminator`, or `nil` if it never
    /// comes.
    package mutating func take(until terminator: UInt8) -> String? {
        guard let end = bytes[index...].firstIndex(of: terminator) else { return nil }
        defer { index = end }
        return String(decoding: bytes[index..<end], as: UTF8.self)
    }

    /// `YYYY-MM-DD`, with the day checked against its month and the year
    /// against 0001–9999.
    package mutating func date() -> Result<(year: Int, month: Int, day: Int), TimeTextFailure> {
        guard let year = digits(4), take("-") != nil, let month = digits(2), take("-") != nil, let day = digits(2) else {
            return .failure(TimeTextFailure("it does not start with a date in the form YYYY-MM-DD"))
        }
        if let failure = Self.check(year: year, month: month, day: day) { return .failure(failure) }
        return .success((year, month, day))
    }

    /// Why `year`-`month`-`day` is not a date, or `nil` if it is one.
    package static func check(year: Int, month: Int, day: Int) -> TimeTextFailure? {
        guard CivilCalendar.years.contains(year) else {
            return TimeTextFailure("the year \(year) is outside 0001–9999")
        }
        guard (1...12).contains(month) else { return TimeTextFailure("there is no month \(month)") }
        let length = CivilCalendar.daysIn(month: month, year: year)
        guard (1...length).contains(day) else {
            return TimeTextFailure("month \(month) of \(year) has \(length) days, not \(day)")
        }
        return nil
    }

    /// `hh:mm`, `hh:mm:ss` or `hh:mm:ss.fff…`, as hours, minutes, seconds
    /// and the fraction of a second in attoseconds.
    ///
    /// - Parameters:
    ///   - requireSeconds: RFC 3339 needs seconds; ISO 8601's plain times
    ///     may leave them out.
    ///   - fractionDigits: The finest digit kept: 9 for nanoseconds, 18 for
    ///     attoseconds. More digits are refused unless they are zeros, never
    ///     rounded away.
    package mutating func time(
        requireSeconds: Bool, fractionDigits: Int
    ) -> Result<(hour: Int, minute: Int, second: Int, attoseconds: Int64), TimeTextFailure> {
        guard let hour = digits(2), take(":") != nil, let minute = digits(2) else {
            return .failure(TimeTextFailure("the time is not in the form hh:mm"))
        }
        guard hour <= 23 else {
            return .failure(TimeTextFailure(hour == 24 ? "the hour 24 is the next day's 00" : "there is no hour \(hour)"))
        }
        guard minute <= 59 else { return .failure(TimeTextFailure("there is no minute \(minute)")) }
        guard take(":") != nil else {
            if requireSeconds { return .failure(TimeTextFailure("it has no seconds; RFC 3339 needs hh:mm:ss")) }
            return .success((hour, minute, 0, 0))
        }
        guard let second = digits(2) else { return .failure(TimeTextFailure("the seconds are not two digits")) }
        guard second <= 59 else {
            return .failure(
                TimeTextFailure(second == 60 ? "it is a leap second, which Unix time does not count" : "there is no second \(second)"))
        }
        guard take(".") != nil else { return .success((hour, minute, second, 0)) }
        var attoseconds: Int64 = 0
        var scale: Int64 = 100_000_000_000_000_000
        var count = 0
        while let byte = next, byte >= 0x30, byte <= 0x39 {
            index += 1
            count += 1
            let digit = Int64(byte - 0x30)
            if count <= fractionDigits {
                attoseconds += digit * scale
                scale /= 10
            } else if digit != 0 {
                let unit = fractionDigits == 9 ? "a nanosecond" : "an attosecond"
                return .failure(TimeTextFailure("its fraction of a second is finer than \(unit), which it cannot hold"))
            }
        }
        guard count > 0 else { return .failure(TimeTextFailure("a `.` must be followed by digits")) }
        return .success((hour, minute, second, attoseconds))
    }

    /// An offset from UTC: `Z` (when `allowZ`), or `±hh:mm`, or (when
    /// `allowSeconds`) `±hh:mm:ss`. In seconds east of Greenwich.
    package mutating func offset(allowZ: Bool, allowSeconds: Bool) -> Result<Int, TimeTextFailure> {
        if allowZ, take("Zz") != nil { return .success(0) }
        guard let sign = take("+-") else {
            if isAtEnd {
                return .failure(
                    TimeTextFailure(
                        allowZ
                            ? "it has no offset, so it names no instant; end it with `Z` for UTC or an offset such as `+02:00`"
                            : "it has no offset; write the offset the zone gave, such as `-04:00`"))
            }
            return .failure(TimeTextFailure("the offset is not `Z` or in the form ±hh:mm"))
        }
        guard let hours = digits(2), take(":") != nil, let minutes = digits(2) else {
            return .failure(TimeTextFailure("the offset is not in the form ±hh:mm"))
        }
        var seconds = 0
        if allowSeconds, next == UInt8(ascii: ":") {
            index += 1
            guard let value = digits(2) else { return .failure(TimeTextFailure("the offset's seconds are not two digits")) }
            seconds = value
        }
        guard hours <= 23, minutes <= 59, seconds <= 59 else {
            return .failure(TimeTextFailure("the offset \(hours):\(minutes) is not an offset from UTC"))
        }
        let total = hours * 3600 + minutes * 60 + seconds
        return .success(sign == UInt8(ascii: "-") ? -total : total)
    }
}

/// The writing half: the same pieces, spelt the way every text form of
/// Stoic writes them.
package enum TimeTextWriter {
    /// `value` in decimal, zero-padded to `width` digits.
    package static func padded(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return text.count >= width ? text : String(repeating: "0", count: width - text.count) + text
    }

    /// `YYYY-MM-DD`.
    package static func date(year: Int, month: Int, day: Int) -> String {
        "\(padded(year, 4))-\(padded(month, 2))-\(padded(day, 2))"
    }

    /// `.5`, `.000001`: the fraction of a second with no trailing zeros, or
    /// nothing for a whole second. `attoseconds` is below a second.
    package static func fraction(attoseconds: Int64) -> String {
        guard attoseconds > 0 else { return "" }
        var digits = padded(Int(attoseconds), 18)
        while digits.last == "0" { digits.removeLast() }
        return "." + digits
    }

    /// `+02:00`, `-04:56:02`: hours and minutes, and seconds only when the
    /// offset has them (an offset from local mean time, before standard
    /// time).
    package static func offset(seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let magnitude = abs(seconds)
        var text = "\(sign)\(padded(magnitude / 3600, 2)):\(padded(magnitude / 60 % 60, 2))"
        if magnitude % 60 != 0 { text += ":" + padded(magnitude % 60, 2) }
        return text
    }
}
