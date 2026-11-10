/// The arithmetic of the proleptic Gregorian calendar, the one ISO 8601 and
/// RFC 3339 use: leap years, month lengths, and the count of days between a
/// date and 1970-01-01.
///
/// Package-wide, not public: ``Moment`` needs it to read and write its text,
/// and `StoicTime`'s calendar types are built on it, so the two cannot
/// disagree about a day. It is pure integer arithmetic (Howard Hinnant's
/// `days_from_civil` and `civil_from_days`), exact for every year an `Int`
/// can hold a day count for.
package enum CivilCalendar {
    /// The first and last years the text forms can write: four digits, and
    /// no year zero (which is 1 BC in the proleptic calendar, and which
    /// RFC 3339 leaves out of its range).
    package static let years: ClosedRange<Int> = 1...9999

    /// Days from 1970-01-01 to 0001-01-01 and to 9999-12-31.
    package static let firstDay = -719_162
    package static let lastDay = 2_932_896

    package static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    /// The number of days in `month` (1...12) of `year`.
    package static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// Days since 1970-01-01 of a valid date; negative before it.
    package static func daysSinceEpoch(year: Int, month: Int, day: Int) -> Int {
        let shifted = month <= 2 ? year - 1 : year
        let era = (shifted >= 0 ? shifted : shifted - 399) / 400
        let yearOfEra = shifted - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// The date `days` after 1970-01-01.
    package static func date(daysSinceEpoch days: Int) -> (year: Int, month: Int, day: Int) {
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

    /// The ISO weekday of the day `days` after 1970-01-01: 1 for Monday
    /// through 7 for Sunday. 1970-01-01 was a Thursday.
    package static func isoWeekday(daysSinceEpoch days: Int) -> Int {
        let fromMonday = (days + 3) % 7
        return (fromMonday < 0 ? fromMonday + 7 : fromMonday) + 1
    }
}

/// Floor division and its remainder, for day and second counts that may be
/// negative (before 1970): the remainder is never negative.
package func floorDivision(_ value: Int128, by divisor: Int128) -> (quotient: Int128, remainder: Int128) {
    var quotient = value / divisor
    var remainder = value % divisor
    if remainder < 0 {
        remainder += divisor
        quotient -= 1
    }
    return (quotient, remainder)
}
