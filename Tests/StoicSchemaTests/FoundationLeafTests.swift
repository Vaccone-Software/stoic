import Foundation
import StoicJSON
import StoicSchema
import StoicTesting
import Testing

/// An API model that holds one of each Foundation leaf, in every format.
struct Wire: Sendable, Equatable {
    var created = Date(timeIntervalSince1970: 0)
    var seen = Date(timeIntervalSince1970: 0)
    var clicked = Date(timeIntervalSince1970: 0)
    var home = URL(string: "https://example.com")!
    var link = URL(string: "/")!
    var id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    var blob = Data()
    var token = Data()

    static let schema = Schema.object(Wire.self, default: Wire(), unknownKeys: .reject) {
        Field("created", \.created, .date(), doc: "When it was made.")
        Field("seen", \.seen, .date(.epochSeconds), doc: "Unix time.")
        Field("clicked", \.clicked, .date(.epochMilliseconds), doc: "JavaScript time.")
        Field("home", \.home, .url(), doc: "A link.")
        Field("link", \.link, .url(.relative), doc: "A reference.")
        Field("id", \.id, .uuid, doc: "Identity.")
        Field("blob", \.blob, .data(), doc: "Bytes.")
        Field("token", \.token, .data(.base64url), doc: "Bytes for a URL.")
    }
}

/// A secret date.
struct Held: Sendable { var at = Date(timeIntervalSince1970: 0) }

private func instant(_ text: String) -> Date? {
    Schema<Date>.date().decode(.string(text)).value
}

@Suite("Dates")
struct DateSchemaTests {
    @Test func rfc3339IsReadWithFractionsAndOffsets() {
        let noon = Date(timeIntervalSince1970: 1_714_566_600)  // 2024-05-01T12:30:00Z
        #expect(instant("2024-05-01T12:30:00Z") == noon)
        #expect(instant("2024-05-01T14:30:00+02:00") == noon)
        #expect(instant("2024-05-01T14:30:00+0200") == noon)
        #expect(instant("2024-05-01T05:00:00-07:30") == noon)
        #expect(instant("2024-05-01t12:30:00z") == noon)
        #expect(instant("2024-05-01 12:30:00Z") == noon)
        #expect(instant("2024-05-01T12:30:00.000Z") == noon)
        #expect(instant("2024-05-01T12:30:00.25Z") == Date(timeIntervalSince1970: 1_714_566_600.25))
        #expect(instant("1969-12-31T23:59:59Z") == Date(timeIntervalSince1970: -1))
        #expect(instant("0000-01-01T00:00:00Z") == Date(timeIntervalSince1970: -62_167_219_200))
        #expect(instant("2000-02-29T00:00:00Z") != nil)
    }

    @Test func writtenInUTCWithTheDigitsItNeeds() {
        let schema = Schema<Date>.date()
        #expect(schema.encode(Date(timeIntervalSince1970: 1_714_566_600)) == "2024-05-01T12:30:00Z")
        #expect(schema.encode(Date(timeIntervalSince1970: 1_714_566_600.5)) == "2024-05-01T12:30:00.5Z")
        #expect(schema.encode(instant("2024-05-01T12:30:00.123Z")!) == "2024-05-01T12:30:00.123Z")
        #expect(schema.encode(instant("2024-05-01T12:30:00.123456Z")!) == "2024-05-01T12:30:00.123456Z")
        #expect(schema.encode(instant("2024-05-01T14:30:00.25+02:00")!) == "2024-05-01T12:30:00.25Z")
        #expect(schema.encode(Date(timeIntervalSince1970: -0.5)) == "1969-12-31T23:59:59.5Z")
    }

    @Test func anyDateInRangeSurvivesARoundTrip() {
        var random = SeededGenerator(seed: 4)
        let schema = Schema<Date>.date()
        for _ in 0..<2000 {
            let seconds = Double.random(in: -62_000_000_000...253_000_000_000, using: &random)
            let date = Date(timeIntervalSince1970: seconds)
            let written = schema.encode(date)
            #expect(schema.decode(written).value == date, "\(seconds) was written as \(written)")
        }
    }

    @Test(.failureMode("design/06", "a date-time is not RFC 3339"))
    func aDateThatIsNotOneSaysWhy() {
        let cases: [(String, String)] = [
            ("2024-02-30T00:00:00Z", "month 2 of 2024 has 29 days, not 30"),
            ("2023-02-29T00:00:00Z", "month 2 of 2023 has 28 days, not 29"),
            ("2024-13-01T00:00:00Z", "there is no month 13"),
            ("2024-05-01T24:00:00Z", "there is no hour 24"),
            ("2024-05-01T12:60:00Z", "there is no minute 60"),
            ("2016-12-31T23:59:60Z", "it is a leap second, which a `Date` cannot hold"),
            ("2024-05-01T12:30:00", "it has no time zone offset, so it names no instant; end it with `Z` for UTC or an offset such as `+02:00`"),
            ("2024-05-01", "it is a date without a time; write a time and an offset, such as `T00:00:00Z`"),
            ("2024-05-01T12:30Z", "it has no seconds; RFC 3339 needs `hh:mm:ss`"),
            ("2024-05-01T12:30:00.Z", "a `.` must be followed by digits"),
            ("9999-12-31T23:59:59-01:00", "in UTC it falls outside the years 0000 to 9999"),
            ("yesterday", "it is not in the form YYYY-MM-DDThh:mm:ss with an offset such as `Z` or `+02:00`"),
            ("2024-05-01T12:30:00+25:00", "the offset 25:0 is not a time zone offset"),
        ]
        for (text, reason) in cases {
            let result = Schema<Date>.date().decode(.string(text))
            #expect(result.value == nil, "\(text)")
            #expect(result.issues.map(\.code) == [.invalidFormat], "\(text)")
            #expect(result.issues.first?.parameters["message"]?.string == reason, "\(text)")
            #expect(result.issues.first?.parameters["format"]?.string == "date-time", "\(text)")
        }
        let issue = Schema<Date>.date().decode(.string("2024-02-30T00:00:00Z")).issues[0]
        #expect(
            issue.message
                == #""2024-02-30T00:00:00Z" is not an RFC 3339 date-time, such as "2024-05-01T12:30:00Z": month 2 of 2024 has 29 days, not 30"#)
    }

    @Test func aNumberWhereADateTimeBelongsIsATypeMismatch() {
        let result = Schema<Date>.date().decode(1_714_566_600)
        #expect(result.issues.map(\.code) == [.typeMismatch])
    }

    @Test func epochSecondsAndMilliseconds() {
        let seconds = Schema<Date>.date(.epochSeconds)
        #expect(seconds.decode(1_714_566_600).value == Date(timeIntervalSince1970: 1_714_566_600))
        #expect(seconds.decode(1_714_566_600.5).value == Date(timeIntervalSince1970: 1_714_566_600.5))
        #expect(seconds.encode(Date(timeIntervalSince1970: 1_714_566_600)) == 1_714_566_600)
        #expect(seconds.encode(Date(timeIntervalSince1970: -1.25)) == -1.25)
        #expect(seconds.decode(1e12).issues.map(\.code) == [.outOfRange])
        #expect(seconds.decode(.string("1714566600")).issues.map(\.code) == [.typeMismatch])

        let milliseconds = Schema<Date>.date(.epochMilliseconds)
        #expect(milliseconds.decode(1_714_566_600_123).value == Date(timeIntervalSince1970: 1_714_566_600.123))
        #expect(milliseconds.encode(Date(timeIntervalSince1970: 1_714_566_600.123)) == 1_714_566_600_123)
        #expect(milliseconds.decode(1.5).issues.map(\.code) == [.typeMismatch])
        #expect(milliseconds.decode(1e16).issues.map(\.code) == [.outOfRange])
    }

    @Test func aDateOutsideTheYearsRFC3339CanWriteIsReportedByValidate() {
        let far = Date(timeIntervalSince1970: 1e12)
        #expect(Schema<Date>.date().validate(far).map(\.code) == [.outOfRange])
        #expect(Schema<Date>.date(.epochSeconds).validate(far).map(\.code) == [.outOfRange])
    }

    @Test func theExportSaysDateTime() {
        let exported = Schema<Date>.date().jsonSchema()
        #expect(exported.object?["type"] == "string")
        #expect(exported.object?["format"] == "date-time")
        #expect(Schema<Date>.date(.epochSeconds).jsonSchema().object?["type"] == "number")
        #expect(Schema<Date>.date(.epochMilliseconds).jsonSchema().object?["type"] == "integer")
    }
}

@Suite("URLs, UUIDs and bytes")
struct IdentifierSchemaTests {
    @Test func absoluteURLsByDefault() {
        let schema = Schema<URL>.url()
        #expect(schema.decode(.string("https://example.com/a?b=1")).value == URL(string: "https://example.com/a?b=1"))
        #expect(schema.decode(.string("mailto:a@example.com")).value != nil)
        let relative = schema.decode(.string("/users/42"))
        #expect(relative.issues.map(\.code) == [.invalidFormat])
        #expect(
            relative.issues.first?.parameters["message"]?.string
                == "it is a relative reference; an absolute URL starts with a scheme such as `https:`")
        let spaced = schema.decode(.string("https://example.com/a b"))
        #expect(spaced.issues.first?.parameters["message"]?.string == "it contains a space, which a URL must percent-encode (`%20`)")
        #expect(schema.decode(.string("")).issues.map(\.code) == [.invalidFormat])
        #expect(schema.encode(URL(string: "https://example.com/a")!) == "https://example.com/a")
        #expect(schema.jsonSchema().object?["format"] == "uri")
    }

    @Test func relativeReferencesWhenAsked() {
        let schema = Schema<URL>.url(.relative)
        for text in ["/users/42", "a/b", "../up", "#top", "https://example.com"] {
            #expect(schema.decode(.string(text)).value?.absoluteString == text, "\(text)")
        }
        #expect(schema.decode(.string("not a url")).issues.map(\.code) == [.invalidFormat])
        #expect(schema.jsonSchema().object?["format"] == "uri-reference")
    }

    @Test func uuidsAreReadInEitherCaseAndWrittenInLowerCase() {
        let schema = Schema<UUID>.uuid
        let upper = schema.decode(.string("123E4567-E89B-12D3-A456-426614174000")).value
        let lower = schema.decode(.string("123e4567-e89b-12d3-a456-426614174000")).value
        #expect(upper != nil && upper == lower)
        #expect(schema.encode(upper!) == "123e4567-e89b-12d3-a456-426614174000")
        #expect(schema.jsonSchema().object?["format"] == "uuid")
    }

    @Test func aUUIDWithoutHyphensIsRefusedWithTheHyphenatedForm() {
        for text in ["123e4567e89b12d3a456426614174000", "{123E4567-E89B-12D3-A456-426614174000}"] {
            let result = Schema<UUID>.uuid.decode(.string(text))
            #expect(result.issues.map(\.code) == [.invalidFormat], "\(text)")
            #expect(result.issues.first?.suggestions == ["123e4567-e89b-12d3-a456-426614174000"], "\(text)")
        }
        #expect(Schema<UUID>.uuid.decode(.string("abc")).issues.first?.message == #""abc" is not a UUID, such as "123e4567-e89b-12d3-a456-426614174000""#)
    }

    @Test func base64() {
        let schema = Schema<Data>.data()
        #expect(schema.decode(.string("SGVsbG8=")).value == Data("Hello".utf8))
        #expect(schema.encode(Data("Hello".utf8)) == "SGVsbG8=")
        #expect(schema.decode(.string("")).value == Data())
        let reasons: [(String, String)] = [
            ("SGVsbG8", "its length, 7, is not a multiple of 4: is the `=` padding missing?"),
            ("SGVs bG8=", "it contains whitespace"),
            ("-_8=", "it uses `-` or `_`, which belong to base64url, not standard base64"),
            ("SGV*", "`*` is not a base64 character"),
            ("S=Vs", "its `=` padding is misplaced"),
        ]
        for (text, reason) in reasons {
            let issue = schema.decode(.string(text)).issues.first
            #expect(issue?.code == .invalidFormat, "\(text)")
            #expect(issue?.parameters["message"]?.string == reason, "\(text)")
        }
        let exported = schema.jsonSchema().object
        #expect(exported?["format"] == "byte")
        #expect(exported?["contentEncoding"] == "base64")
    }

    @Test func base64url() {
        let schema = Schema<Data>.data(.base64url)
        let bytes = Data([0xFB, 0xFF, 0xBF])
        #expect(schema.encode(bytes) == "-_-_")
        #expect(schema.decode(.string("-_-_")).value == bytes)
        #expect(schema.decode(.string("SGVsbG8")).value == Data("Hello".utf8))
        #expect(schema.decode(.string("SGVsbG8=")).value == Data("Hello".utf8))
        #expect(schema.decode(.string("+/+/")).issues.first?.code == .invalidFormat)
        #expect(schema.jsonSchema().object?["contentEncoding"] == "base64url")
    }
}

@Suite("Foundation leaves in an object")
struct FoundationLeafObjectTests {
    @Test func everyIssueIsReportedAtItsPath() {
        let result = Wire.schema.decodeReporting(
            #"{"created": "2024-02-30T00:00:00Z", "seen": "x", "home": "/a", "id": "nope", "blob": "***="}"#)
        #expect(result.issues.locations == [
            "$.created invalid_format", "$.seen type_mismatch", "$.home invalid_format", "$.id invalid_format",
            "$.blob invalid_format",
        ])
        #expect(result.issues.map { $0.source?.start.description ?? "" } == ["1:13", "1:45", "1:58", "1:70", "1:86"])
    }

    @Test func aSecretDateKeepsItsValueAndReasonToItself() {
        let schema = Schema.object(Held.self, default: Held()) { Field("at", \.at, .date(), secret: true) }
        let issue = schema.decode(["at": "2024-02-30T00:00:00Z"]).issues[0]
        #expect(issue.code == .invalidFormat)
        #expect(issue.actual == nil)
        #expect(issue.parameters["message"] == nil)
        #expect(!issue.description.contains("02-30"))
    }

    @Test func theSuiteHolds() {
        let report = SchemaSuite(Wire.schema).report(seed: 2, cases: 150)
        #expect(report.isClean, "\(report)")
        #expect(report.skipped == 0)
        #expect((report.tally[.mutations]?.runs ?? 0) > 300)
    }

    @Test func theGeneratorOffersEveryCounterexample() throws {
        var refused: Set<String> = []
        for seed in 0..<UInt64(20) {
            let sample = try Wire.schema.generator.sample(seed: seed)
            for mutation in Wire.schema.generator.mutations(of: sample.document, seed: seed)
            where mutation.kind == .refusedByConversion {
                refused.insert(mutation.location.description)
                #expect(Wire.schema.decode(mutation.document).errors.map(\.code) == [.invalidFormat])
            }
        }
        #expect(refused == ["$.created", "$.home", "$.link", "$.id", "$.blob", "$.token"])
    }

    @Test func theTypesAreSchematic() {
        #expect(Date.schema.jsonSchema() == Schema<Date>.date().jsonSchema())
        #expect(URL.schema.jsonSchema() == Schema<URL>.url().jsonSchema())
        #expect(UUID.schema.jsonSchema() == Schema<UUID>.uuid.jsonSchema())
        #expect(Data.schema.jsonSchema() == Schema<Data>.data().jsonSchema())
        let ids = [UUID].schema.decode(.array(["123e4567-e89b-12d3-a456-426614174000"]))
        #expect(ids.value?.count == 1)
    }
}
