public import Stoic
public import StoicSchema

// Schema leaves for the time types: each reads and writes the type's text
// form, refuses the others' (a date where a moment is expected is one
// `invalid_format` issue saying so), and exports as a JSON string with the
// JSON Schema `format` where there is one.

extension Schema where Value == Moment {
    /// A moment, as RFC 3339 text: `2026-11-09T18:34:12.425Z`. Any offset is
    /// read; it is written in UTC, exactly.
    public static var moment: Schema<Moment> {
        .formatted(
            name: "Moment", format: "date-time",
            describe: #"an RFC 3339 date-time with an offset, such as "2026-11-09T18:34:12.425Z""#,
            examples: [
                "1970-01-01T00:00:00Z", "2026-11-09T18:34:12.425Z", "2027-03-14T09:00:00-04:00", "0001-01-01T00:00:00Z",
                "9999-12-31T23:59:59.999999999Z", "2024-02-29T12:00:00.5+05:30",
            ],
            counterexamples: ["2027-03-14", "2027-03-14T09:00", "2026-02-30T00:00:00Z", "2027-03-14T09:00:00-04:00[America/New_York]"],
            parse: { text in Moment.parse(rfc3339: text).mapError { FormatFailure($0.message) } },
            print: { $0.rfc3339 })
    }
}

extension Schema where Value == PlainDate {
    /// A calendar date, as ISO 8601 text: `2027-03-14`.
    public static var plainDate: Schema<PlainDate> {
        .formatted(
            name: "PlainDate", format: "date", describe: #"a calendar date, such as "2027-03-14""#,
            examples: ["2027-03-14", "2024-02-29", "0001-01-01", "9999-12-31", "1970-01-01"],
            counterexamples: ["2026-11-09T18:34:12Z", "2027-02-29", "2027-3-14", "14/03/2027"],
            parse: { text in PlainDate.parse(text).mapError { FormatFailure($0.message) } },
            print: { $0.description })
    }
}

extension Schema where Value == PlainTime {
    /// A time of day, as ISO 8601 text: `09:00`, `09:00:30.5`.
    public static var plainTime: Schema<PlainTime> {
        .formatted(
            name: "PlainTime", format: nil, describe: #"a time of day, such as "09:00" or "09:00:30.5""#,
            examples: ["00:00", "09:00", "23:59:59.999999999", "12:30:15", "09:00:30.5"],
            counterexamples: ["24:00", "09:00Z", "9:00", "09:60"],
            parse: { text in PlainTime.parse(text).mapError { FormatFailure($0.message) } },
            print: { $0.description })
    }
}

extension Schema where Value == PlainDateTime {
    /// A local date and time with no zone, as ISO 8601 text: `2027-03-14T09:00`.
    public static var plainDateTime: Schema<PlainDateTime> {
        .formatted(
            name: "PlainDateTime", format: nil, describe: #"a local date and time, such as "2027-03-14T09:00""#,
            examples: ["2027-03-14T09:00", "2024-02-29T23:59:59.5", "0001-01-01T00:00", "9999-12-31T23:59:59.999999999"],
            counterexamples: ["2027-03-14T09:00:00Z", "2027-03-14", "2027-03-14T25:00", "2027-03-14 09:00"],
            parse: { text in PlainDateTime.parse(text).mapError { FormatFailure($0.message) } },
            print: { $0.description })
    }
}

extension Schema where Value == ZonedDateTime {
    /// A zoned date-time, as RFC 9557 text:
    /// `2027-03-14T09:00:00-04:00[America/New_York]`. Read without the zone
    /// rules, so an offset the zone no longer gives is read, stale, not
    /// refused (``ZonedDateTime/init(parsing:)``).
    public static var zonedDateTime: Schema<ZonedDateTime> {
        .formatted(
            name: "ZonedDateTime", format: nil,
            describe: #"an RFC 9557 date-time with its zone, such as "2027-03-14T09:00:00-04:00[America/New_York]""#,
            examples: [
                "2027-03-14T09:00:00-04:00[America/New_York]", "2027-03-14T01:30:00+11:00[Australia/Sydney]",
                "2026-11-09T18:34:12.425+00:00[UTC]", "2027-01-01T00:00:00+05:30[+05:30]",
                "1883-11-18T12:00:00-04:56:02[America/New_York]",
            ],
            counterexamples: [
                "2027-03-14T09:00:00-04:00", "2027-03-14T13:00:00Z[America/New_York]", "2027-03-14T09:00[America/New_York]",
                "2027-03-14T09:00:00-04:00[America/New York]",
            ],
            parse: { text in ZonedDateTime.parse(text).mapError { FormatFailure($0.message) } },
            print: { $0.description })
    }
}

extension Schema where Value == Period {
    /// A calendar period, as ISO 8601 text: `P1M`, `P7D`, `-P1Y`.
    public static var period: Schema<Period> {
        .formatted(
            name: "Period", format: nil, describe: #"an ISO 8601 period of years, months and days, such as "P1M" or "P7D""#,
            examples: ["P0D", "P7D", "P1M", "P1Y2M3D", "-P1M", "P1M-3D"],
            counterexamples: ["PT1H", "7 days", "P", "1M"],
            parse: { text in Period.parse(text).mapError { FormatFailure($0.message) } },
            print: { $0.description })
    }
}

extension Schema where Value == TimeZoneID {
    /// A time zone's IANA name, `America/New_York`, or an RFC 9557 offset,
    /// `+05:30`. Whether the rules know the zone is asked when it is used,
    /// not here.
    public static var timeZoneID: Schema<TimeZoneID> {
        .formatted(
            name: "TimeZoneID", format: nil, describe: #"a time zone name, such as "America/New_York""#,
            examples: ["America/New_York", "Europe/London", "UTC", "Australia/Lord_Howe", "America/Argentina/Buenos_Aires", "+05:30"],
            counterexamples: ["America/New York", "", "../etc", "+5:30"],
            parse: { text in
                TimeZoneID.problem(with: text).map { .failure(FormatFailure($0)) } ?? .success(TimeZoneID(unchecked: text))
            },
            print: { $0.identifier })
    }
}

extension Moment: Schematic {
    /// RFC 3339, as `Schema<Moment>.moment` reads and writes it.
    public static var schema: Schema<Moment> { .moment }
}

extension PlainDate: Schematic {
    public static var schema: Schema<PlainDate> { .plainDate }
}

extension PlainTime: Schematic {
    public static var schema: Schema<PlainTime> { .plainTime }
}

extension PlainDateTime: Schematic {
    public static var schema: Schema<PlainDateTime> { .plainDateTime }
}

extension ZonedDateTime: Schematic {
    public static var schema: Schema<ZonedDateTime> { .zonedDateTime }
}

extension Period: Schematic {
    public static var schema: Schema<Period> { .period }
}

extension TimeZoneID: Schematic {
    public static var schema: Schema<TimeZoneID> { .timeZoneID }
}
