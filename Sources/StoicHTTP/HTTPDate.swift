internal import Stoic

/// Parses the three HTTP-date formats of RFC 9110 §5.6.7.
///
/// A recipient must accept all three, though a sender may produce only the
/// first:
///
///     Sun, 06 Nov 1994 08:49:37 GMT      IMF-fixdate
///     Sunday, 06-Nov-94 08:49:37 GMT     obsolete RFC 850 (two-digit year)
///     Sun Nov  6 08:49:37 1994           ANSI C asctime()
///
/// Written by hand rather than with a `DateFormatter`: a formatter is
/// expensive to build, its parse depends on locale and calendar settings
/// that must all be pinned, and one format string cannot read three layouts.
/// The arithmetic is the proleptic Gregorian calendar in UTC, which is all
/// HTTP dates are, and the result a `Moment`: the kernel's calendar, so an
/// HTTP date and a moment's text cannot disagree about a day.
enum HTTPDate {
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let days = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    /// The instant `text` names, or `nil` if it is none of the three formats.
    ///
    /// - Parameter now: Resolves a two-digit year, as RFC 9110 directs: a
    ///   date that would be more than 50 years ahead is the latest past year
    ///   with the same last two digits.
    static func parse(_ text: String, now: Moment) -> Moment? {
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if text.contains(",") {
            // IMF-fixdate: ["Sun,", "06", "Nov", "1994", "08:49:37", "GMT"]
            // RFC 850:     ["Sunday,", "06-Nov-94", "08:49:37", "GMT"]
            guard let first = tokens.first, first.hasSuffix(","), isDayName(first.dropLast()) else { return nil }
            if tokens.count == 6 {
                guard let day = Int(tokens[1]), let month = monthNumber(tokens[2]), let year = fourDigitYear(tokens[3]),
                      isGMT(tokens[5]) else { return nil }
                return build(year: year, month: month, day: day, time: tokens[4])
            }
            if tokens.count == 4 {
                let parts = tokens[1].split(separator: "-", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 3, let day = Int(parts[0]), let month = monthNumber(parts[1]),
                      parts[2].count == 2, let twoDigits = Int(parts[2]), isGMT(tokens[3]) else { return nil }
                guard let date = build(year: pastCentury(twoDigits, now: now, day: day, month: month, time: tokens[2]),
                                       month: month, day: day, time: tokens[2]) else { return nil }
                return date
            }
            return nil
        }
        // asctime: ["Sun", "Nov", "6", "08:49:37", "1994"]
        guard tokens.count == 5, isDayName(Substring(tokens[0])), let month = monthNumber(tokens[1]),
              let day = Int(tokens[2]), let year = fourDigitYear(tokens[4]) else { return nil }
        return build(year: year, month: month, day: day, time: tokens[3])
    }

    private static func isDayName(_ name: Substring) -> Bool {
        let lowered = name.lowercased()
        return name.count == 3
            ? days.contains { $0.hasPrefix(lowered) }
            : days.contains(lowered)
    }

    private static func monthNumber(_ name: String) -> Int? {
        months.firstIndex(of: name.lowercased()).map { $0 + 1 }
    }

    private static func fourDigitYear(_ text: String) -> Int? {
        text.count == 4 ? Int(text) : nil
    }

    private static func isGMT(_ zone: String) -> Bool {
        zone == "GMT"
    }

    /// The year for a two-digit RFC 850 year, per RFC 9110 §5.6.7.
    private static func pastCentury(_ twoDigits: Int, now: Moment, day: Int, month: Int, time: String) -> Int {
        let (nowDays, _) = floorDivision(now.sinceEpoch.attoseconds, by: 86_400 * 1_000_000_000_000_000_000)
        let nowYear = CivilCalendar.date(daysSinceEpoch: Int(nowDays)).year
        var year = nowYear / 100 * 100 + twoDigits
        // Fifty years of 365.2425 days.
        if let candidate = build(year: year, month: month, day: day, time: time),
           now.duration(to: candidate) > .seconds(1_577_836_800) {
            year -= 100
        }
        return year
    }

    private static func build(year: Int, month: Int, day: Int, time: String) -> Moment? {
        let clock = time.split(separator: ":", omittingEmptySubsequences: false)
        guard clock.count == 3, clock.allSatisfy({ $0.count == 2 }),
              let hour = Int(clock[0]), let minute = Int(clock[1]), let second = Int(clock[2]),
              hour < 24, minute < 60, second <= 60,   // 60: a leap second
              (1...12).contains(month), day >= 1, day <= CivilCalendar.daysIn(month: month, year: year) else { return nil }
        let days = CivilCalendar.daysSinceEpoch(year: year, month: month, day: day)
        return Moment(sinceEpoch: .seconds(Int64(days) * 86_400 + Int64(hour * 3600 + minute * 60 + second)))
    }
}
