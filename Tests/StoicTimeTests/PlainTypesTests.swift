import Foundation
import Stoic
import StoicTesting
import StoicTime
import Testing

@Suite("Plain dates and times")
struct PlainTypesTests {
    // MARK: Construction

    @Test(.failureMode("design/26", "a date that does not exist is made (30 February, month 13)"))
    func aDateThatDoesNotExistIsRefusedAtConstruction() {
        #expect(throws: TimeError.invalid("month 2 of 2027 has 28 days, not 30")) { try PlainDate(2027, 2, 30) }
        #expect(throws: TimeError.invalid("month 2 of 2027 has 28 days, not 29")) { try PlainDate(2027, 2, 29) }
        #expect(throws: TimeError.invalid("there is no month 13")) { try PlainDate(2027, 13, 1) }
        #expect(throws: TimeError.invalid("there is no month 0")) { try PlainDate(2027, 0, 1) }
        #expect(throws: TimeError.invalid("month 4 of 2027 has 30 days, not 31")) { try PlainDate(2027, 4, 31) }
        #expect(throws: TimeError.invalid("month 1 of 2027 has 31 days, not 0")) { try PlainDate(2027, 1, 0) }
        #expect(throws: TimeError.outOfRange("the year 0 is outside 0001–9999")) { try PlainDate(0, 1, 1) }
        #expect(throws: TimeError.outOfRange("the year 10000 is outside 0001–9999")) { try PlainDate(10_000, 1, 1) }
        #expect(throws: TimeError.invalid("the hour 24 is the next day's 00")) { try PlainTime(24, 0) }
        #expect(throws: TimeError.invalid("there is no minute 60")) { try PlainTime(9, 60) }
        #expect(throws: TimeError.invalid("a leap second, which the zone rules do not count")) { try PlainTime(23, 59, 60) }
        #expect(throws: (any Error).self) { try PlainTime(9, 0, nanosecond: 1_000_000_000) }
        // Nothing rolls over: the text form refuses the same dates.
        #expect(throws: TimeError.self) { try PlainDate(parsing: "2027-02-29") }
        #expect(throws: TimeError.self) { try PlainDateTime(parsing: "2027-02-30T09:00") }

        #expect(Zones.date(2024, 2, 29).daysInMonth == 29)
        let time = Zones.time(9, 5, 30)
        #expect((time.hour, time.minute, time.second, time.nanosecond) == (9, 5, 30, 0))
    }

    @Test func weekdaysFollowTheISOCalendar() {
        #expect(Zones.date(1970, 1, 1).weekday == .thursday)
        #expect(Zones.date(2027, 3, 14).weekday == .sunday)
        #expect(Zones.date(2026, 1, 1).weekday == .thursday)
        #expect(Zones.date(1, 1, 1).weekday == .monday)
        #expect(Zones.date(9999, 12, 31).weekday == .friday)
        #expect(Weekday.monday.rawValue == 1 && Weekday.sunday.rawValue == 7)
    }

    // MARK: Calendar arithmetic

    @Test(.failureMode("design/26", "a month is added to the 31st"))
    func aMonthAddedToTheThirtyFirstIsDecidedByTheNamedOverflow() throws {
        let end = Zones.date(2027, 1, 31)
        #expect(try end.adding(.months(1)) == Zones.date(2027, 2, 28))
        #expect(try end.adding(.months(1), overflow: .constrain) == Zones.date(2027, 2, 28))
        #expect(try Zones.date(2028, 1, 31).adding(.months(1)) == Zones.date(2028, 2, 29))
        #expect(throws: TimeError.invalid("month 2 of 2027 has 28 days, not 31")) {
            try end.adding(.months(1), overflow: .reject)
        }
        #expect(try end.adding(Period(months: 1, days: 1)) == Zones.date(2027, 3, 1), "months first, then days")
        #expect(try end.adding(.months(2), overflow: .reject) == Zones.date(2027, 3, 31), "a day the month has is kept")
        #expect(try Zones.date(2024, 2, 29).adding(.years(1)) == Zones.date(2025, 2, 28))
        #expect(try Zones.date(2027, 3, 31).adding(.months(-1)) == Zones.date(2027, 2, 28))
        #expect(try Zones.date(2027, 3, 14).adding(.weeks(1)) == Zones.date(2027, 3, 21))
        #expect(try Zones.date(2027, 3, 14).adding(.days(-365)) == Zones.date(2026, 3, 14))
        #expect(throws: TimeError.self) { try Zones.date(9999, 12, 31).adding(.days(1)) }
        #expect(throws: TimeError.self) { try Zones.date(1, 1, 1).adding(.months(-1)) }
        #expect(throws: TimeError.self) { try Zones.date(2027, 1, 1).adding(.years(Int.max)) }
    }

    @Test func periodsBetweenDatesAddBack() throws {
        #expect(Zones.date(2027, 1, 31).period(to: Zones.date(2027, 3, 1)) == Period(months: 1, days: 1))
        #expect(Zones.date(2027, 3, 31).period(to: Zones.date(2027, 2, 28)) == Period(months: -1))
        #expect(Zones.date(2027, 3, 1).period(to: Zones.date(2027, 1, 31)) == Period(months: -1, days: -1))
        #expect(Zones.date(2000, 2, 29).period(to: Zones.date(2027, 3, 14)) == Period(years: 27, days: 14))
        #expect(Zones.date(2027, 3, 14).period(to: Zones.date(2027, 3, 14)) == .zero)
        #expect(Zones.date(2027, 3, 14).days(to: Zones.date(2028, 3, 14)) == 366)

        var random = RandomSource.seeded(14).generator()
        for _ in 0..<5_000 {
            let a = try randomDate(&random), b = try randomDate(&random)
            let period = a.period(to: b)
            #expect(try a.adding(period) == b, "\(a) + \(period) should be \(b)")
            let signs = [period.years, period.months, period.days].filter { $0 != 0 }.map { $0 > 0 }
            #expect(Set(signs).count <= 1, "\(period) has one sign")
        }
    }

    /// Every day from 1600 to 2400, counted one at a time by the naive rule
    /// (the next day of the month, or the first of the next), against the
    /// arithmetic: the day count, the date it gives back, the weekday, and
    /// adding days.
    @Test func dateArithmeticAgreesWithCountingDaysFrom1600To2400() throws {
        var (year, month, day) = (1600, 1, 1)
        let start = Zones.date(1600, 1, 1)
        var count = 0
        var weekday = start.weekday.rawValue
        var random = RandomSource.seeded(1600).generator()
        while year <= 2400 {
            let date = try PlainDate(year, month, day)
            #expect(start.days(to: date) == count)
            #expect(date.weekday.rawValue == weekday)
            if count % 97 == 0 {
                #expect(try start.adding(.days(count)) == date)
                let step = Int.random(in: -40_000...40_000, using: &random)
                let moved = try date.adding(.days(step))
                #expect(date.days(to: moved) == step)
                #expect(try moved.adding(.days(-step)) == date)
            }
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            let length = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
            day += 1
            if day > length { (month, day) = (month + 1, 1) }
            if month > 12 { (year, month) = (year + 1, 1) }
            count += 1
            weekday = weekday % 7 + 1
        }
        #expect(count == 292_560, "801 years, 195 of them leap years")
    }

    @Test(.failureMode("design/26", "a birthday is read in a zone west of UTC"))
    func aBirthdayIsTheSameDayInEveryZone() async throws {
        // Stored as a plain date, a birthday has no zone to shift it. Read
        // west of UTC (New York), east of it (Kolkata), and with the device
        // in either, it is the day it was stored as.
        let birthday = try PlainDate(parsing: "2010-07-04")
        let rules = Zones.rules()
        // The bug this prevents: the same birthday kept as midnight UTC is
        // the 3rd in New York.
        let asInstant = try await onTestTime(rules) { try Zones.moment("2010-07-04T00:00:00Z").in(Zones.newYork) }
        #expect(asInstant.local.date == Zones.date(2010, 7, 3))
        for zone in [Zones.newYork, Zones.kolkata, TimeZoneID.utc] {
            rules.deviceZone = zone
            try await onTestTime(rules) {
                let stored = try JSONEncoder().encode(["birthday": birthday])
                let read = try JSONDecoder().decode([String: PlainDate].self, from: stored)["birthday"]
                #expect(read == birthday)
                #expect(read?.description == "2010-07-04")
                #expect(read?.weekday == .sunday)
                // The age is asked on the day it is in a place, and is the
                // same arithmetic wherever that is.
                #expect(birthday.age(on: try PlainDate.today(in: .device)) == 15)
            }
        }
    }

    @Test(.failureMode("design/26", "a person born on 29 February is aged in a non-leap year"))
    func aLeapDayBirthdayIsCountedByTheNamedRule() {
        let born = Zones.date(2008, 2, 29)
        let eve = Zones.date(2027, 2, 28), next = Zones.date(2027, 3, 1)
        #expect(born.age(on: eve) == 18)
        #expect(born.age(on: eve, leapDayBirthday: .marchFirst) == 18)
        #expect(born.age(on: next, leapDayBirthday: .marchFirst) == 19)
        #expect(born.age(on: eve, leapDayBirthday: .februaryLast) == 19)
        #expect(born.age(on: Zones.date(2027, 2, 27), leapDayBirthday: .februaryLast) == 18)
        // In a leap year the birthday is its own day under either rule.
        #expect(born.age(on: Zones.date(2028, 2, 28), leapDayBirthday: .februaryLast) == 19)
        #expect(born.age(on: Zones.date(2028, 2, 29), leapDayBirthday: .marchFirst) == 20)
        #expect(Zones.date(2010, 7, 4).age(on: Zones.date(2010, 7, 3)) == -1, "negative before the birth")
        #expect(Zones.date(2010, 7, 4).age(on: Zones.date(2010, 7, 4)) == 0)
    }

    // MARK: Text

    @Test func textFormsAreReadAndWritten() throws {
        #expect(Zones.date(2027, 3, 14).description == "2027-03-14")
        #expect(Zones.date(1, 1, 1).description == "0001-01-01")
        #expect(Zones.time(9, 0).description == "09:00")
        #expect(Zones.time(9, 0, 30).description == "09:00:30")
        #expect(try PlainTime(9, 0, 30, nanosecond: 500_000_000).description == "09:00:30.5")
        #expect(try PlainTime(9, 0, 0, nanosecond: 1).description == "09:00:00.000000001")
        #expect(Zones.local(2027, 3, 14, 9, 0).description == "2027-03-14T09:00")
        #expect(try PlainTime(parsing: "09:00:30.5") == PlainTime(9, 0, 30, nanosecond: 500_000_000))
        #expect(try PlainTime(parsing: "09:00:00.000") == Zones.time(9, 0))
        #expect(try PlainDateTime(parsing: "2027-03-14t09:00") == Zones.local(2027, 3, 14, 9, 0))
        #expect(PlainTime.midnight.description == "00:00" && PlainTime.noon.description == "12:00")

        #expect(Period(years: 1, months: 2, days: 3).description == "P1Y2M3D")
        #expect(Period.days(7).description == "P7D")
        #expect(Period.zero.description == "P0D")
        #expect(Period(months: -1, days: -3).description == "-P1M3D")
        #expect(Period(months: 1, days: -3).description == "P1M-3D")
        #expect(try Period(parsing: "P2W") == .days(14))
        #expect(try Period(parsing: "P1W2D") == .days(9))
        #expect(try Period(parsing: "-P1M3D") == Period(months: -1, days: -3))
        #expect(try Period(parsing: "+P1Y") == .years(1))
        #expect(Period.months(12) != Period.years(1), "the fields are kept as given")

        #expect(throws: TimeError.self) { try PlainTime(parsing: "9:00") }
        #expect(throws: TimeError.self) { try PlainTime(parsing: "09:00:00.0000000001") }
        #expect(throws: TimeError.self) { try PlainDateTime(parsing: "2027-03-14 09:00") }
        #expect(throws: TimeError.self) { try PlainDateTime(parsing: "2027-03-14T09:00Z") }
        #expect(throws: TimeError.self) { try PlainDate(parsing: "2027-03-14T09:00") }
        for text in ["PT1H", "P", "1M", "P1D1M", "P1M1M", "P1.5D", "P1H", "P99999999999999999999D"] {
            #expect(throws: TimeError.self, "\(text)") { try Period(parsing: text) }
        }
    }

    /// Every type's text reads back as the same value, and its Codable form
    /// is that text.
    @Test func textRoundTripsForEveryPlainType() throws {
        var random = RandomSource.seeded(26).generator()
        for _ in 0..<5_000 {
            let date = try randomDate(&random)
            let time = try PlainTime(
                Int.random(in: 0...23, using: &random), Int.random(in: 0...59, using: &random),
                Bool.random(using: &random) ? 0 : Int.random(in: 0...59, using: &random),
                nanosecond: [0, 500_000_000, Int.random(in: 0..<1_000_000_000, using: &random)].randomElement(using: &random) ?? 0)
            let local = PlainDateTime(date, time)
            let period = Period(
                years: Int.random(in: -50...50, using: &random), months: Int.random(in: -30...30, using: &random),
                days: Int.random(in: -400...400, using: &random))
            #expect(try PlainDate(parsing: date.description) == date)
            #expect(try PlainTime(parsing: time.description) == time)
            #expect(try PlainDateTime(parsing: local.description) == local)
            #expect(try Period(parsing: period.description) == period)
            #expect(try roundTrip(date) == date)
            #expect(try roundTrip(time) == time)
            #expect(try roundTrip(local) == local)
            #expect(try roundTrip(period) == period)
        }
        #expect(try roundTrip(Zones.newYork) == Zones.newYork)
        let offsetName = "+05:30"
        #expect(try TimeZoneID(offsetName).identifier == "+05:30", "a String, not a literal, so the throwing init")
        for bad in ["", "America/New York", "America//New_York", "../etc", "-Etc", "+5:30", "+05:30:00"] {
            #expect(throws: TimeError.self, "\(bad)") { try TimeZoneID(bad) }
        }
    }

    @Test func codableRefusesWithTheReason() {
        let error = #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([PlainDate].self, from: Data(#"["2027-02-30"]"#.utf8))
        }
        guard case .dataCorrupted(let context)? = error else { return }
        #expect(context.debugDescription == #""2027-02-30" is not a date: month 2 of 2027 has 28 days, not 30"#)
    }
}

func randomDate(_ random: inout RandomGenerator) throws -> PlainDate {
    let year = Int.random(in: 1600...2400, using: &random)
    let month = Int.random(in: 1...12, using: &random)
    let length = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
        + (month == 2 && ((year % 4 == 0 && year % 100 != 0) || year % 400 == 0) ? 1 : 0)
    return try PlainDate(year, month, Int.random(in: 1...length, using: &random))
}

func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
    try JSONDecoder().decode([Value].self, from: JSONEncoder().encode([value]))[0]
}
