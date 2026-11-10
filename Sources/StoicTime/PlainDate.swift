internal import Stoic

/// A day on the calendar, with no zone and no time: a birthday, a due date,
/// the day of an event.
///
///     let born = try PlainDate(2010, 7, 4)
///     let isMinor = born.age(on: try PlainDate.today(in: event.zone)) < 18
///
/// A plain date is not an instant, so nothing can shift it. A birthday
/// stored as a `Date` at midnight UTC is shown a day early west of
/// Greenwich; one stored as a `PlainDate` is the same day everywhere, because
/// there is no zone in it to convert from. Which day it is *now* is a
/// question about a place, so ``today(in:)`` takes one.
///
/// The calendar is ISO 8601's, the proleptic Gregorian, for the years 0001
/// to 9999. A date that does not exist (30 February, month 13) cannot be
/// made: it is ``TimeError/invalid(_:)`` at construction, never a date
/// silently rolled over into the next month. Its text is `2027-03-14`.
public struct PlainDate: Sendable, Hashable, Comparable {
    /// The year, 1 to 9999.
    public let year: Int
    /// The month, 1 (January) to 12.
    public let month: Int
    /// The day of the month, from 1.
    public let day: Int

    /// The date `year`-`month`-`day`, or ``TimeError/invalid(_:)`` if there
    /// is no such day (``TimeError/outOfRange(_:)`` for a year outside 0001
    /// to 9999).
    public init(_ year: Int, _ month: Int, _ day: Int) throws(TimeError) {
        guard CivilCalendar.years.contains(year) else {
            throw .outOfRange("the year \(year) is outside 0001–9999")
        }
        if let failure = TimeTextScanner.check(year: year, month: month, day: day) {
            throw .invalid(failure.message)
        }
        self.init(unchecked: year, month, day)
    }

    /// A date already known to exist.
    init(unchecked year: Int, _ month: Int, _ day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The date `days` after 1970-01-01, or ``TimeError/outOfRange(_:)``.
    init(daysSinceEpoch days: Int) throws(TimeError) {
        guard days >= CivilCalendar.firstDay, days <= CivilCalendar.lastDay else {
            throw .outOfRange("the date is outside the years 0001–9999")
        }
        let (year, month, day) = CivilCalendar.date(daysSinceEpoch: days)
        self.init(unchecked: year, month, day)
    }

    /// Days since 1970-01-01; negative before it.
    var daysSinceEpoch: Int {
        CivilCalendar.daysSinceEpoch(year: year, month: month, day: day)
    }

    /// The day of the week.
    public var weekday: Weekday {
        Weekday.allCases[CivilCalendar.isoWeekday(daysSinceEpoch: daysSinceEpoch) - 1]
    }

    /// The number of days in this date's month.
    public var daysInMonth: Int {
        CivilCalendar.daysIn(month: month, year: year)
    }

    /// Today, in `zone`: the day it is there now, by the ambient wall clock
    /// (`Moment.now`) and the zone rules in force.
    ///
    /// There is no "today" without a place, so the place is said: the
    /// event's zone for the event's day, ``TimeZoneID/device`` for the
    /// person's own.
    ///
    /// - Throws: ``TimeError/unknownZone(_:)`` if the rules do not know `zone`.
    public static func today(in zone: TimeZoneID) throws(TimeError) -> PlainDate {
        try Moment.now.in(zone).local.date
    }

    public static func < (lhs: PlainDate, rhs: PlainDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

// MARK: - Calendar arithmetic

extension PlainDate {
    /// What adding months does to a day the new month does not have: the
    /// 31st plus a month.
    public enum Overflow: Sendable, Hashable {
        /// The last day of the month instead: 31 January plus a month is 28
        /// (or 29) February. Temporal's and java.time's default.
        case constrain
        /// ``TimeError/invalid(_:)``: the caller decides.
        case reject
    }

    /// How a birthday on 29 February is counted in a year without one.
    public enum LeapDayRule: Sendable, Hashable {
        /// The birthday is 1 March: the person is a year older once 28
        /// February has passed. The rule in the United Kingdom, Hong Kong
        /// and New Zealand, among others.
        case marchFirst
        /// The birthday is 28 February. The rule in Taiwan, among others.
        case februaryLast
    }

    /// The date `period` later on the calendar (earlier, for a negative one).
    ///
    /// Years and months move first, together, and the day is kept unless
    /// the month is shorter, which `overflow` decides; then the days are
    /// added. So 31 January plus a month is 28 February under
    /// ``Overflow/constrain``, and plus a month and a day is 1 March. This is
    /// calendar arithmetic, not elapsed time: a month is not thirty days.
    ///
    /// - Throws: ``TimeError/invalid(_:)`` when `overflow` is
    ///   ``Overflow/reject`` and the day does not exist in the month reached;
    ///   ``TimeError/outOfRange(_:)`` past the years 0001 to 9999.
    public func adding(_ period: Period, overflow: Overflow = .constrain) throws(TimeError) -> PlainDate {
        let (yearMonths, overflowA) = period.years.multipliedReportingOverflow(by: 12)
        let (months, overflowB) = yearMonths.addingReportingOverflow(period.months)
        guard !overflowA, !overflowB else { throw .outOfRange("\(period) is more months than a date can move") }
        let moved = try addingMonths(months, overflow: overflow)
        let (days, overflowC) = moved.daysSinceEpoch.addingReportingOverflow(period.days)
        guard !overflowC else { throw .outOfRange("\(period) is more days than a date can move") }
        return try PlainDate(daysSinceEpoch: days)
    }

    /// The date `months` later, the day constrained or refused.
    private func addingMonths(_ months: Int, overflow: Overflow) throws(TimeError) -> PlainDate {
        guard months != 0 else { return self }
        guard let (newYear, newMonth) = monthShifted(by: months), CivilCalendar.years.contains(newYear) else {
            throw .outOfRange("the date is outside the years 0001–9999")
        }
        let length = CivilCalendar.daysIn(month: newMonth, year: newYear)
        if day > length, overflow == .reject {
            throw .invalid("month \(newMonth) of \(newYear) has \(length) days, not \(day)")
        }
        return PlainDate(unchecked: newYear, newMonth, min(day, length))
    }

    /// The year and month `months` after this date's, or `nil` if the
    /// count overflows. Counted as months since year 0, so it is one
    /// addition and a floor division.
    private func monthShifted(by months: Int) -> (year: Int, month: Int)? {
        let (index, overflowed) = (year * 12 + month - 1).addingReportingOverflow(months)
        guard !overflowed else { return nil }
        let newYear = index >= 0 ? index / 12 : (index - 11) / 12
        return (newYear, index - newYear * 12 + 1)
    }

    /// The calendar period from this date to `other`: whole years, then
    /// whole months, then days, all of one sign, such that
    /// `adding(period)` (constraining) gives back `other`.
    ///
    /// From 31 January to 1 March is one month and one day: a month reaches
    /// 28 (or 29) February, and the day is the rest. Forwards this is
    /// java.time's `Period.between`; backwards it is the same rule run the
    /// other way, so that from 31 March to 28 February is minus one month
    /// (where `between` says minus a month and three days, which does not
    /// add back).
    public func period(to other: PlainDate) -> Period {
        var months = (other.year * 12 + other.month) - (year * 12 + month)
        var days = other.daysSinceEpoch - reached(months).daysSinceEpoch
        if months > 0, days < 0 {
            months -= 1
            days = other.daysSinceEpoch - reached(months).daysSinceEpoch
        } else if months < 0, days > 0 {
            months += 1
            days = other.daysSinceEpoch - reached(months).daysSinceEpoch
        }
        return Period(years: months / 12, months: months % 12, days: days)
    }

    /// This date `months` on, its day constrained: for a count of months
    /// that stays between two valid dates, so it is in range.
    private func reached(_ months: Int) -> PlainDate {
        let (newYear, newMonth) = monthShifted(by: months) ?? (year, month)
        return PlainDate(unchecked: newYear, newMonth, min(day, CivilCalendar.daysIn(month: newMonth, year: newYear)))
    }

    /// The number of days from this date to `other`: positive when `other`
    /// is later.
    public func days(to other: PlainDate) -> Int {
        other.daysSinceEpoch - daysSinceEpoch
    }

    /// The age, in whole years, on `day` of someone born on this date.
    ///
    /// A year is counted on each birthday, and a 29 February birthday in a
    /// year without one is counted as `leapDayBirthday` says. A plain date
    /// has no zone, so the answer is the same wherever it is asked: pass the
    /// day it is where the answer matters (``today(in:)``). Negative when
    /// `day` is before the birth.
    public func age(on day: PlainDate, leapDayBirthday: LeapDayRule = .marchFirst) -> Int {
        var birthday = (month: month, day: self.day)
        if month == 2, self.day == 29, !CivilCalendar.isLeapYear(day.year) {
            birthday = leapDayBirthday == .marchFirst ? (3, 1) : (2, 28)
        }
        let years = day.year - year
        return (day.month, day.day) < (birthday.month, birthday.day) ? years - 1 : years
    }
}

// MARK: - Text

extension PlainDate: CustomStringConvertible {
    /// The ISO 8601 calendar date: `2027-03-14`.
    public var description: String {
        TimeTextWriter.date(year: year, month: month, day: day)
    }

    /// Reads an ISO 8601 calendar date, `YYYY-MM-DD`.
    ///
    /// - Throws: ``TimeError/invalid(_:)`` with the reason: a day the month
    ///   does not have, or text that is not a date, including a moment's or
    ///   a date-time's (the forms do not overlap).
    public init(parsing text: String) throws(TimeError) {
        switch Self.parse(text) {
        case .success(let date): self = date
        case .failure(let failure): throw .invalid("\"\(text)\" is not a date: \(failure.message)")
        }
    }

    static func parse(_ text: String) -> Result<PlainDate, TimeTextFailure> {
        var scanner = TimeTextScanner(text)
        switch scanner.date() {
        case .success(let date):
            guard scanner.isAtEnd else {
                return .failure(TimeTextFailure("it goes on after the date; a date with a time is a date-time or a moment, not a date"))
            }
            return .success(PlainDate(unchecked: date.year, date.month, date.day))
        case .failure(let failure):
            return .failure(failure)
        }
    }
}

extension PlainDate: Codable {
    /// Reads the date's text, `2027-03-14`.
    public init(from decoder: any Decoder) throws {
        self = try decodeText(from: decoder, kind: "a date", parse: Self.parse)
    }

    /// Writes the date's text, `2027-03-14`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// The day of the week, numbered as ISO 8601 numbers them: Monday is 1.
public enum Weekday: Int, Sendable, Hashable, CaseIterable {
    case monday = 1, tuesday, wednesday, thursday, friday, saturday, sunday
}

/// A value read from its text through `parse`, with the reason in the
/// `DecodingError` when it is not one.
func decodeText<Value>(
    from decoder: any Decoder, kind: String, parse: (String) -> Result<Value, TimeTextFailure>
) throws -> Value {
    let container = try decoder.singleValueContainer()
    let text = try container.decode(String.self)
    switch parse(text) {
    case .success(let value):
        return value
    case .failure(let failure):
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "\"\(text)\" is not \(kind): \(failure.message)")
    }
}
