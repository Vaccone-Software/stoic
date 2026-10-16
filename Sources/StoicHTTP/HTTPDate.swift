import Foundation

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
/// HTTP dates are.
enum HTTPDate {
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let days = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    /// The instant `text` names, or `nil` if it is none of the three formats.
    ///
    /// - Parameter now: Resolves a two-digit year, as RFC 9110 directs: a
    ///   date that would be more than 50 years ahead is the latest past year
    ///   with the same last two digits.
    static func parse(_ text: String, now: Date) -> Date? {
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
    private static func pastCentury(_ twoDigits: Int, now: Date, day: Int, month: Int, time: String) -> Int {
        let nowYear = civil(daysSinceEpoch: Int(floor(now.timeIntervalSince1970 / 86_400))).year
        var year = nowYear / 100 * 100 + twoDigits
        if let candidate = build(year: year, month: month, day: day, time: time),
           candidate.timeIntervalSince(now) > 50 * 365.2425 * 86_400 {
            year -= 100
        }
        return year
    }

    private static func build(year: Int, month: Int, day: Int, time: String) -> Date? {
        let clock = time.split(separator: ":", omittingEmptySubsequences: false)
        guard clock.count == 3, clock.allSatisfy({ $0.count == 2 }),
              let hour = Int(clock[0]), let minute = Int(clock[1]), let second = Int(clock[2]),
              hour < 24, minute < 60, second <= 60,   // 60: a leap second
              day >= 1, day <= daysIn(month: month, year: year) else { return nil }
        let days = daysSinceEpoch(year: year, month: month, day: day)
        return Date(timeIntervalSince1970: Double(days * 86_400 + hour * 3600 + minute * 60 + second))
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    // Howard Hinnant's days_from_civil and civil_from_days.
    private static func daysSinceEpoch(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func civil(daysSinceEpoch days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shifted = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shifted + 2) / 5 + 1
        let month = shifted < 10 ? shifted + 3 : shifted - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }
}
