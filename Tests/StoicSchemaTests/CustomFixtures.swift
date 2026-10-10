import StoicJSON
import StoicSchema

/// A Foundation-free instant, spelled on the wire as an RFC 3339 UTC string.
/// The base schema carries the shape (so the export and the generators can
/// see it); the conversion carries the rest, which is whether the date
/// exists.
struct Timestamp: Sendable, Equatable, Hashable {
    var secondsSinceEpoch: Int64

    static let schema: Schema<Timestamp> = .transform(
        base: .string(.length(20...20), .pattern(#"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#)),
        decode: { text throws(TransformFailure) in try Timestamp(parsing: text) },
        encode: { $0.rfc3339 },
        describe: "an RFC 3339 UTC timestamp such as 2024-02-29T12:00:00Z",
        examples: [
            Timestamp(secondsSinceEpoch: 0), Timestamp(secondsSinceEpoch: 951_782_400),
            Timestamp(secondsSinceEpoch: 1_709_208_000),
        ])

    init(secondsSinceEpoch: Int64) {
        self.secondsSinceEpoch = secondsSinceEpoch
    }

    /// Reads `YYYY-MM-DDTHH:MM:SSZ`, whose shape the schema's base has
    /// already checked, and refuses dates that do not exist.
    init(parsing text: String) throws(TransformFailure) {
        let digits = text.utf8.map { Int64($0) - 48 }
        func number(_ range: Range<Int>) -> Int64 { range.reduce(0) { $0 * 10 + digits[$1] } }
        let year = number(0..<4)
        let month = number(5..<7)
        let day = number(8..<10)
        let hour = number(11..<13)
        let minute = number(14..<16)
        let second = number(17..<19)
        guard (1...12).contains(month), (1...Self.daysIn(month: month, year: year)).contains(day) else {
            throw TransformFailure("is not a date that exists", suggestions: [])
        }
        guard hour < 24, minute < 60, second < 60 else {
            throw TransformFailure("is not a time of day")
        }
        let days = Self.daysFromCivil(year: year, month: month, day: day)
        secondsSinceEpoch = days * 86_400 + hour * 3600 + minute * 60 + second
    }

    var rfc3339: String {
        let days = secondsSinceEpoch >= 0 ? secondsSinceEpoch / 86_400 : -((-secondsSinceEpoch + 86_399) / 86_400)
        let remainder = secondsSinceEpoch - days * 86_400
        let (year, month, day) = Self.civilFromDays(days)
        func pad(_ value: Int64, _ width: Int) -> String {
            let text = String(value)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))T\(pad(remainder / 3600, 2)):\(pad(remainder % 3600 / 60, 2)):\(pad(remainder % 60, 2))Z"
    }

    static func isLeap(_ year: Int64) -> Bool { year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) }

    static func daysIn(month: Int64, year: Int64) -> Int64 {
        switch month {
        case 2: isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// Howard Hinnant's days-from-civil algorithm.
    static func daysFromCivil(year: Int64, month: Int64, day: Int64) -> Int64 {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civilFromDays(_ days: Int64) -> (Int64, Int64, Int64) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }
}

/// A web address, as far as a configuration file needs one: a scheme and a
/// host, kept apart. A string on the wire.
struct Endpoint: Sendable, Equatable {
    var secure: Bool
    var host: String

    static let schema: Schema<Endpoint> = .transform(
        base: .string(.length(8...300), .pattern(#"^https?://"#)),
        decode: { text throws(TransformFailure) in
            let secure = text.hasPrefix("https://")
            let host = text.dropFirst(secure ? 8 : 7)
            guard !host.isEmpty, !host.contains(" ") else {
                throw TransformFailure("has no usable host", expected: "http(s)://host")
            }
            return Endpoint(secure: secure, host: String(host))
        },
        encode: { ($0.secure ? "https://" : "http://") + $0.host },
        describe: "an http(s) URL",
        examples: [Endpoint(secure: true, host: "example.com"), Endpoint(secure: false, host: "localhost:8080")])
}

/// An integer-valued enumeration, as wire protocols have them.
enum Priority: Int, CaseIterable, Sendable {
    case low = 1
    case normal = 5
    case urgent = 10
}

/// A number of hertz, written either as a number or as text such as
/// `"50Hz"`: a shape only code can describe.
struct Frequency: Sendable, Equatable {
    var hertz: Double

    static let schema: Schema<Frequency> = .custom(
        description: #"a positive number of hertz, or a string such as "50Hz""#,
        examples: [50, "60Hz", 0.5],
        decode: { json, context in
            switch json {
            case .number:
                return context.decode(json, as: Schema<Double>.double(.greaterThan(0))).map(Frequency.init)
            case .string(let text):
                guard text.hasSuffix("Hz"), let value = Double(text.dropLast(2)), value > 0 else {
                    return context.fail("is not a number of hertz", expected: #"a string such as "50Hz""#)
                }
                return Frequency(hertz: value)
            default:
                return context.fail("is neither a number nor a string")
            }
        },
        encode: { frequency in JSONNumber(frequency.hertz).map { .number($0) } ?? .null })

    init(hertz: Double) {
        self.hertz = hertz
    }
}
