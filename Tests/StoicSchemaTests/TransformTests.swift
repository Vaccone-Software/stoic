import StoicJSON
import Testing

@testable import StoicSchema

private func decode<V>(_ schema: Schema<V>, _ text: String, _ options: DecodeOptions = .strict) -> Decoded<V> {
    schema.decodeReporting(text, options: options)
}

@Suite("Transforms")
struct TransformTests {
    @Test func decodesThroughTheBaseThenTheConversion() {
        #expect(decode(Timestamp.schema, #""2024-02-29T12:00:00Z""#).value == Timestamp(secondsSinceEpoch: 1_709_208_000))
        #expect(decode(Timestamp.schema, #""1970-01-01T00:00:00Z""#).value == Timestamp(secondsSinceEpoch: 0))
        #expect(decode(Timestamp.schema, #""1969-12-31T23:59:59Z""#).value == Timestamp(secondsSinceEpoch: -1))
    }

    @Test func theBaseIsCheckedBeforeTheConversionRuns() {
        // A shape error is the base's, with the base's code; the conversion
        // is never asked about a string it was not designed for.
        let result = decode(Timestamp.schema, #""yesterday""#)
        #expect(result.value == nil)
        // Too short; and the pattern is not run on a string whose length failed.
        #expect(result.issues.map(\.code) == [.tooShort])
        let wrongKind = decode(Timestamp.schema, "5")
        #expect(wrongKind.issues.map(\.code) == [.typeMismatch])
    }

    @Test func theBasesOwnIssuesAreAllReported() {
        // 20 characters but not the shape: only the pattern fails.
        let result = decode(Timestamp.schema, #""2024/02/29 12:00:00Z""#)
        #expect(result.issues.map(\.code) == [.patternMismatch])
    }

    @Test func aRefusalFromTheConversionIsOneIssueAtTheValue() {
        let result = decode(Timestamp.schema, #""2023-02-29T00:00:00Z""#)
        #expect(result.value == nil)
        #expect(result.issues.count == 1)
        let issue = result.issues[0]
        #expect(issue.code == .invalidValue)
        #expect(issue.path == .root)
        #expect(issue.expected == "an RFC 3339 UTC timestamp such as 2024-02-29T12:00:00Z")
        #expect(issue.actual == #""2023-02-29T00:00:00Z""#)
        #expect(
            issue.description
                == #"1:1 $: is not a date that exists, expected an RFC 3339 UTC timestamp such as 2024-02-29T12:00:00Z"#)
        #expect(decode(Timestamp.schema, #""2024-04-31T00:00:00Z""#).issues.map(\.code) == [.invalidValue])
        #expect(decode(Timestamp.schema, #""2024-13-01T00:00:00Z""#).issues.map(\.code) == [.invalidValue])
        #expect(decode(Timestamp.schema, #""2024-01-01T24:00:00Z""#).issues[0].message.hasPrefix("is not a time of day"))
        #expect(decode(Timestamp.schema, #""2000-02-29T00:00:00Z""#).value != nil)  // 400-year rule
        #expect(decode(Timestamp.schema, #""1900-02-29T00:00:00Z""#).value == nil)  // 100-year rule
    }

    @Test func aFailureCanNameItsExpectationCodeAndSuggestions() {
        let schema: Schema<Int> = .transform(
            base: .string(),
            decode: { text throws(TransformFailure) in
                guard let number = Int(text) else {
                    throw TransformFailure(
                        "is not a number", code: IssueCode(rawValue: "not_numeric"), expected: "digits", suggestions: ["0"])
                }
                return number
            },
            encode: { String($0) }, describe: "a number in a string")
        let issue = decode(schema, #""x""#).issues[0]
        #expect(issue.code.rawValue == "not_numeric")
        #expect(issue.expected == "digits")
        #expect(issue.suggestions == ["0"])
    }

    @Test func issuesInsideAnObjectCarryPathsAndAccumulate() {
        struct Event: Sendable, Equatable {
            var created = Timestamp(secondsSinceEpoch: 0)
            var home = Endpoint(secure: true, host: "example.com")
            var level = Priority.normal
            var seen: [Timestamp] = []
        }
        let schema = Schema.object(Event.self, default: Event(), unknownKeys: .reject) {
            Field("created", \.created, Timestamp.schema, doc: "When.")
            Field("home", \.home, Endpoint.schema, doc: "Where.")
            Field("level", \.level, .enumeration(Priority.self), doc: "How much.")
            Field("seen", \.seen, .array(of: Timestamp.schema), doc: "When seen.")
        }
        let text = """
            {"created": "2023-02-30T00:00:00Z", "home": "http://a b", "level": 7,
             "seen": ["2024-01-01T00:00:00Z", "2024-06-31T00:00:00Z", 3]}
            """
        let result = schema.decodeReporting(text)
        #expect(
            result.issues.locations == [
                "$.created invalid_value", "$.home invalid_value", "$.level not_one_of", "$.seen[1] invalid_value",
                "$.seen[2] type_mismatch",
            ])
        #expect(result.issues[0].source?.start.line == 1)
        #expect(result.issues[3].source?.start.line == 2)
    }

    @Test func aTransformInsideASecretFieldDoesNotEchoTheValue() {
        struct Vault: Sendable, Equatable { var endpoint = Endpoint(secure: true, host: "example.com") }
        let schema = Schema.object(Vault.self, default: Vault()) {
            Field("endpoint", \.endpoint, Endpoint.schema, secret: true)
        }
        let result = schema.decodeReporting(#"{"endpoint": "https://secret host"}"#)
        #expect(result.issues.map(\.code) == [.invalidValue])
        #expect(result.issues[0].actual == nil)
        #expect(!ValidationFailure(issues: result.issues).description.contains("secret host"))
    }

    @Test func lenientDecodingRepairsARefusedTransformFromTheDefault() {
        struct Event: Sendable, Equatable { var created = Timestamp(secondsSinceEpoch: 86_400) }
        let schema = Schema.object(Event.self, default: Event()) {
            Field("created", \.created, Timestamp.schema)
        }
        let result = schema.decodeReporting(#"{"created": "2023-02-30T00:00:00Z"}"#, options: .lenient)
        #expect(result.value == Event())
        #expect(result.issues.map(\.severity) == [.repaired])
        #expect(result.issues[0].message.hasSuffix("; used the default \"1970-01-02T00:00:00Z\""))
    }

    @Test func encodingIsTheInverseOfDecoding() {
        var random = SeededGenerator(seed: 7)
        for _ in 0..<2000 {
            // From year 0000 to 9999.
            let seconds = Int64.random(in: -62_167_219_200...253_402_300_799, using: &random)
            let stamp = Timestamp(secondsSinceEpoch: seconds)
            let json = Timestamp.schema.encode(stamp)
            #expect(Timestamp.schema.decode(json).value == stamp, "\(seconds) \(json)")
        }
        #expect(Timestamp.schema.encode(Timestamp(secondsSinceEpoch: 951_782_400)) == "2000-02-29T00:00:00Z")
        #expect(Timestamp.schema.encode(Timestamp(secondsSinceEpoch: -62_167_219_200)) == "0000-01-01T00:00:00Z")
    }

    @Test func theNodeIsTheBaseAndTheDescription() {
        guard case .transformed(let transform) = Timestamp.schema.node else { return fail("node") }
        #expect(transform.name == "Timestamp")
        #expect(transform.description.hasPrefix("an RFC 3339"))
        guard case .string(let constraints) = transform.base else { return fail("base") }
        #expect(constraints.count == 2)
        #expect(transform.examples.count == 3)
        #expect(transform.examples[0] == "1970-01-01T00:00:00Z")
        // The constraints of the base are the node's constraints.
        #expect(Timestamp.schema.node.constraints == constraints)
        #expect(Timestamp.schema.node.expectation == transform.description)
    }

    @Test func theExportIsTheBaseWithATransformAnnotation() {
        let document = Timestamp.schema.jsonSchema()
        #expect(document.object?["type"] == "string")
        #expect(document.object?["minLength"] == 20)
        #expect(document.object?["maxLength"] == 20)
        #expect(document.object?["pattern"] != nil)
        let transform = document.object?["x-stoic-transform"]?.object
        #expect(transform?["name"] == "Timestamp")
        #expect(transform?["description"]?.string?.hasPrefix("an RFC 3339") == true)
        // A plain validator agrees with the decoder on everything the base can say.
        let validator = MiniJSONSchema(document)
        #expect(validator.accepts("2024-02-29T12:00:00Z"))
        #expect(!validator.accepts("yesterday"))
        #expect(!validator.accepts(5))
    }

    @Test func constraintsAddedLaterLandOnTheBase() {
        let refined = Timestamp.schema.node.adding([.length(...25)])
        guard case .transformed(let transform) = refined, case .string(let constraints) = transform.base else {
            return fail("node")
        }
        #expect(constraints.count == 3)
    }

    @Test func anOptionalTransformIsAbsentOrPresent() {
        struct Box: Sendable, Equatable { var at: Timestamp? = nil }
        let schema = Schema.object(Box.self, default: Box()) {
            Field("at", \.at, .optional(Timestamp.schema))
        }
        #expect(schema.decodeReporting("{}").value == Box())
        #expect(schema.decodeReporting(#"{"at": "1970-01-01T00:00:01Z"}"#).value == Box(at: Timestamp(secondsSinceEpoch: 1)))
        #expect(schema.decodeReporting(#"{"at": "1970-02-31T00:00:01Z"}"#).issues.map(\.code) == [.invalidValue])
        let sparse = schema.encode(Box(at: Timestamp(secondsSinceEpoch: 1)), style: .sparse)
        #expect(sparse.object?["at"] == "1970-01-01T00:00:01Z")
    }

    @Test func aRequiredTransformInAnObjectWithoutDefaultsIsMissingWhenAbsent() {
        struct Entry: Sendable, Equatable { var at: Timestamp }
        let schema = Schema.object(Entry.self) { f in
            let at = f.field("at", \.at, Timestamp.schema)
            return f.build { v in Entry(at: v[at]) }
        }
        #expect(schema.decodeReporting("{}").issues.locations == ["$.at missing_key"])
    }

    @Test func validateFindsAStructWhoseConversionWouldRefuseIt() {
        // encode is total, but a Value outside what decode accepts is found
        // by validate(), which round-trips through the base's constraints.
        let schema: Schema<Int> = .transform(
            base: .string(.pattern("^[0-9]+$")),
            decode: { text throws(TransformFailure) in
                guard let number = Int(text) else { throw TransformFailure("does not fit") }
                return number
            },
            encode: { String($0) }, describe: "a natural number")
        #expect(schema.validate(5).isEmpty)
        #expect(schema.validate(-5).map(\.code) == [.patternMismatch])
    }
}

@Suite("Integer enumerations")
struct IntegerEnumerationTests {
    @Test func decodesRawValues() {
        let schema = Schema.enumeration(Priority.self)
        #expect(decode(schema, "1").value == .low)
        #expect(decode(schema, "5").value == .normal)
        #expect(decode(schema, "10").value == .urgent)
    }

    @Test func aNumberThatNamesNoCaseIsRefusedWithTheRawValuesListed() {
        let result = decode(Schema.enumeration(Priority.self), "7")
        #expect(result.issues.map(\.code) == [.notOneOf])
        #expect(result.issues[0].expected == "one of 1, 5, 10")
        #expect(result.issues[0].description == "1:1 $: 7 is not allowed, expected one of 1, 5, 10")
    }

    @Test func otherKindsOfValueAreTypeMismatches() {
        let schema = Schema.enumeration(Priority.self)
        #expect(decode(schema, "1.5").issues.map(\.code) == [.typeMismatch])
        #expect(decode(schema, #""high""#).issues.map(\.code) == [.typeMismatch])
        #expect(decode(schema, "null").issues.map(\.code) == [.typeMismatch])
        #expect(decode(schema, #""5""#).issues[0].suggestions == ["5"])
        #expect(decode(schema, "9223372036854775808").issues.map(\.code) == [.outOfRange])
    }

    @Test func oneThatIsSpelledLikeAFloatIsOnlyLenientlyAccepted() {
        let schema = Schema.enumeration(Priority.self)
        #expect(decode(schema, "5.0").value == nil)
        let lenient = decode(schema, "5.0", .lenient)
        #expect(lenient.value == .normal)
        #expect(lenient.warnings.count == 1)
    }

    @Test func encodesTheRawValue() {
        #expect(Schema.enumeration(Priority.self).encode(.urgent) == 10)
        for priority in Priority.allCases {
            let schema = Schema.enumeration(Priority.self)
            #expect(schema.decode(schema.encode(priority)).value == priority)
        }
    }

    @Test func theNodeKeepsTheCaseNamesAndTheExportListsTheValues() {
        guard case .integerEnumeration(let name, let cases) = Schema.enumeration(Priority.self).node else {
            return fail("node")
        }
        #expect(name == "Priority")
        #expect(cases == [
            IntegerCase(name: "low", value: 1), IntegerCase(name: "normal", value: 5),
            IntegerCase(name: "urgent", value: 10),
        ])
        let document = Schema.enumeration(Priority.self).jsonSchema().object
        #expect(document?["type"] == "integer")
        #expect(document?["enum"] == [1, 5, 10])
        #expect(document?["x-stoic-enum-names"] == ["low", "normal", "urgent"])
    }

    @Test func aSecretIntegerEnumerationDoesNotEchoTheNumber() {
        struct Gate: Sendable, Equatable { var level = Priority.low }
        let schema = Schema.object(Gate.self, default: Gate()) {
            Field("level", \.level, .enumeration(Priority.self), secret: true)
        }
        let issue = schema.decodeReporting(#"{"level": 7}"#).issues[0]
        #expect(issue.code == .notOneOf)
        #expect(issue.actual == nil)
    }
}

@Suite("Custom schemas")
struct CustomSchemaTests {
    @Test func decodesEitherSpelling() {
        #expect(decode(Frequency.schema, "50").value == Frequency(hertz: 50))
        #expect(decode(Frequency.schema, "0.5").value == Frequency(hertz: 0.5))
        #expect(decode(Frequency.schema, #""60Hz""#).value == Frequency(hertz: 60))
    }

    @Test func aCustomDecoderReportsThroughTheContext() {
        let result = decode(Frequency.schema, #""fast""#)
        #expect(result.issues.map(\.code) == [.invalidValue])
        #expect(result.issues[0].expected == #"a string such as "50Hz""#)
        #expect(result.issues[0].message == #"is not a number of hertz, expected a string such as "50Hz""#)
        #expect(decode(Frequency.schema, "true").issues[0].message == "is neither a number nor a string")
    }

    @Test func aSubSchemaReportsItsOwnIssues() {
        let result = decode(Frequency.schema, "-3")
        #expect(result.issues.map(\.code) == [.outOfRange])
    }

    @Test func issuesBelowTheValueGetTheRightPath() {
        struct Range: Sendable, Equatable { var low: Int; var high: Int }
        let schema = Schema<Range>.custom(
            description: "an object with low below high",
            decode: { json, context in
                guard case .object(let object) = json else { return context.fail("is not an object") }
                let low = object["low"].flatMap { context.decode($0, as: Schema<Int>.int(), at: .key("low")) }
                let high = object["high"].flatMap { context.decode($0, as: Schema<Int>.int(), at: .key("high")) }
                if object["low"] == nil { context.report("is missing", code: .missingKey, at: [.key("low")]) }
                guard let low, let high else { return nil }
                if low >= high { context.report("must be below high", at: [.key("low")], actual: String(low)) }
                return Range(low: low, high: high)
            },
            encode: { ["low": .number(JSONNumber($0.low)), "high": .number(JSONNumber($0.high))] })
        struct Holder: Sendable, Equatable { var range = Range(low: 0, high: 1) }
        let holder = Schema.object(Holder.self, default: Holder()) {
            Field("range", \.range, schema)
        }
        let result = holder.decodeReporting(#"{"range": {"low": 5, "high": 5}}"#)
        #expect(result.value == nil)
        #expect(result.issues.locations == ["$.range.low invalid_value"])
        #expect(result.issues[0].source?.start.column == 19)  // the text of `low`'s value
        #expect(holder.decodeReporting(#"{"range": {"high": "x"}}"#).issues.locations == [
            "$.range.low missing_key", "$.range.high type_mismatch",
        ])
        #expect(holder.decodeReporting(#"{"range": {"low": 1, "high": 2}}"#).value == Holder(range: Range(low: 1, high: 2)))
    }

    @Test func aDecoderThatReturnsNilWithoutReportingStillFails() {
        let schema = Schema<Int>.custom(
            description: "never", decode: { _, _ in nil }, encode: { .number(JSONNumber($0)) })
        let result = decode(schema, "1")
        #expect(result.value == nil)
        #expect(result.issues.map(\.code) == [.invalidValue])
    }

    @Test func aDecoderThatReportsAnErrorAndStillReturnsAValueFails() {
        let schema = Schema<Int>.custom(
            description: "bad",
            decode: { _, context in
                context.report("went wrong")
                return 5
            },
            encode: { .number(JSONNumber($0)) })
        let result = decode(schema, "1")
        #expect(result.value == nil)
        #expect(result.issues.count == 1)
    }

    @Test func aWarningDoesNotFailTheDecode() {
        let schema = Schema<Int>.custom(
            description: "an integer, with a nag",
            decode: { json, context in
                context.report("is old style", severity: .warning)
                return json.number?.int64.map(Int.init)
            },
            encode: { .number(JSONNumber($0)) })
        let result = decode(schema, "3")
        #expect(result.value == 3)
        #expect(result.warnings.count == 1)
    }

    @Test func theNodeAndExportDescribeTheBase() {
        let document = Frequency.schema.jsonSchema().object
        #expect(document?["x-stoic-transform"]?.object?["name"] == "Frequency")
        // `describing:` defaulted to any JSON value: nothing but the annotation.
        #expect(document?["type"] == nil)
        guard case .transformed(let transform) = Frequency.schema.node else { return fail("node") }
        #expect(transform.examples == [50, "60Hz", 0.5])
    }

    @Test func encodingUsesTheClosure() {
        #expect(Frequency.schema.encode(Frequency(hertz: 50)) == 50)
        #expect(Frequency.schema.decode(Frequency.schema.encode(Frequency(hertz: 12.5))).value == Frequency(hertz: 12.5))
    }
}
