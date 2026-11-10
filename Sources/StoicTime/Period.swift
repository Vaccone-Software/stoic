internal import Stoic

/// An amount of calendar time: years, months and days, as a calendar counts
/// them.
///
///     let due = try invoice.date.adding(.days(30))
///     let renewal = try plan.start.adding(.months(1))
///
/// Not a `Duration`. A month is 28 to 31 days and a day in a zone with
/// daylight saving is 23 to 25 hours, so a period means something only
/// against a date: ``PlainDate/adding(_:overflow:)``. Elapsed time is a
/// `Duration`, added to a `Moment`; there is no `Moment + Period`, because
/// that needs a zone, and the code should say which.
///
/// The fields are kept as given: twelve months is not a year, and
/// `.months(12) != .years(1)`, though both move a date the same. Its text is
/// ISO 8601's duration with date parts only: `P1Y2M3D`, `P7D`, `-P1M`.
public struct Period: Sendable, Hashable {
    public var years: Int
    public var months: Int
    public var days: Int

    public init(years: Int = 0, months: Int = 0, days: Int = 0) {
        self.years = years
        self.months = months
        self.days = days
    }

    public static func years(_ years: Int) -> Period { Period(years: years) }
    public static func months(_ months: Int) -> Period { Period(months: months) }
    public static func days(_ days: Int) -> Period { Period(days: days) }

    /// `weeks` seven-day weeks, as days.
    public static func weeks(_ weeks: Int) -> Period { Period(days: weeks * 7) }

    /// No time at all.
    public static let zero = Period()

    public var isZero: Bool { years == 0 && months == 0 && days == 0 }

    /// The same amount the other way.
    public static prefix func - (period: Period) -> Period {
        Period(years: -period.years, months: -period.months, days: -period.days)
    }
}

extension Period: CustomStringConvertible {
    /// ISO 8601: `P1Y2M3D`, with the zero parts left out and `P0D` for
    /// nothing. A period whose parts are all negative is written with one
    /// sign in front, `-P1M3D`; one whose parts disagree, with a sign on
    /// each negative part, `P1M-3D`, as java.time writes it.
    public var description: String {
        if isZero { return "P0D" }
        let allNegative = years <= 0 && months <= 0 && days <= 0
        let shown = allNegative ? -self : self
        var text = allNegative ? "-P" : "P"
        if shown.years != 0 { text += "\(shown.years)Y" }
        if shown.months != 0 { text += "\(shown.months)M" }
        if shown.days != 0 { text += "\(shown.days)D" }
        return text
    }

    /// Reads an ISO 8601 period of years, months, weeks and days: `P1Y2M3D`,
    /// `P2W` (fourteen days), `-P1M`, `P1M-3D`.
    ///
    /// - Throws: ``TimeError/invalid(_:)`` with the reason, including for a
    ///   time part (`PT1H`): hours and seconds are a `Duration`.
    public init(parsing text: String) throws(TimeError) {
        switch Self.parse(text) {
        case .success(let period): self = period
        case .failure(let failure): throw .invalid("\"\(text)\" is not a period: \(failure.message)")
        }
    }

    static func parse(_ text: String) -> Result<Period, TimeTextFailure> {
        var scanner = TimeTextScanner(text)
        let negated = scanner.take("+-") == UInt8(ascii: "-")
        guard scanner.take("P") != nil else {
            return .failure(TimeTextFailure("it does not start with `P`, as an ISO 8601 period does (`P1M`, `P7D`)"))
        }
        var period = Period()
        var parts = 0
        // The designators in the order ISO 8601 requires them.
        var remaining: [UInt8] = Array("YMWD".utf8)
        while !scanner.isAtEnd {
            if scanner.next == UInt8(ascii: "T") {
                return .failure(TimeTextFailure("it has a time part; a period counts calendar days, and hours are a Duration"))
            }
            let negative = scanner.take("+-") == UInt8(ascii: "-")
            guard let magnitude = scanner.number(upTo: 18) else {
                return .failure(TimeTextFailure("each part is a number followed by Y, M, W or D"))
            }
            guard let designator = scanner.next, let position = remaining.firstIndex(of: designator) else {
                return .failure(TimeTextFailure("each part is a number followed by Y, M, W or D, in that order, once each"))
            }
            _ = scanner.take("YMWD")
            remaining.removeSubrange(...position)
            let value = negative ? -magnitude : magnitude
            switch designator {
            case UInt8(ascii: "Y"): period.years = value
            case UInt8(ascii: "M"): period.months = value
            case UInt8(ascii: "W"):
                let (days, overflow) = value.multipliedReportingOverflow(by: 7)
                guard !overflow else { return .failure(TimeTextFailure("the weeks are too many to count in days")) }
                period.days = days
            default:
                let (days, overflow) = period.days.addingReportingOverflow(value)
                guard !overflow else { return .failure(TimeTextFailure("the days are too many to count")) }
                period.days = days
            }
            parts += 1
        }
        guard parts > 0 else { return .failure(TimeTextFailure("it has no parts; nothing at all is `P0D`")) }
        return .success(negated ? -period : period)
    }
}

extension Period: Codable {
    /// Reads the period's ISO 8601 text, `P1M`.
    public init(from decoder: any Decoder) throws {
        self = try decodeText(from: decoder, kind: "a period", parse: Self.parse)
    }

    /// Writes the period's ISO 8601 text, `P1M`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
