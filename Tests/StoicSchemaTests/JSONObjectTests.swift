import StoicJSON
import StoicSchemaTesting
import StoicTesting
import Testing

@testable import StoicSchema

/// A document whose top level must be an object, and the two things the text
/// entry points say about the text that a schema's value does not hold.
@Suite("Schema.jsonObject and the text's own issues")
struct JSONObjectTests {
    @Test(.failureMode("design/06", "a schema that wants any object meets another kind of value"))
    func aTopLevelThatIsNotAnObjectIsATypeMismatchWithItsPosition() throws {
        let schema = Schema.jsonObject()
        for (text, kind) in [("[1, 2]", "an array"), ("5", "a number"), ("\"x\"", "a string"), ("null", "null"), ("true", "a boolean")] {
            let decoded = schema.decodeReporting(text)
            #expect(decoded.value == nil, "\(text)")
            let issue = try #require(decoded.errors.first)
            #expect(issue.code == .typeMismatch)
            #expect(issue.expected == "an object")
            #expect(issue.source?.start.line == 1)
            #expect(issue.message.hasPrefix("expected an object, found "), "\(issue.message)")
            #expect(issue.parameters["found"]?.string != nil, "\(kind)")
        }
        #expect(try #require(schema.decodeReporting("  \n [1]").errors.first).source?.start.line == 2)
    }

    @Test func anyObjectIsPassedThroughUntouched() throws {
        let schema = Schema.jsonObject()
        let text = #"{"a": 1, "b": {"c": [true, null]}, "d": "x"}"#
        let value = try #require(schema.decodeReporting(text).value)
        #expect(value == json(text))
        #expect(schema.encode(value) == value)
        #expect(schema.decodeReporting("{}").value == .object([:]))
    }

    @Test func constraintsAreAboutTheEntries() throws {
        let schema = Schema.jsonObject(.count(1...2))
        #expect(schema.decodeReporting("{}").value == nil)
        #expect(schema.decodeReporting(#"{"a": 1}"#).value != nil)
        #expect(schema.decodeReporting(#"{"a": 1, "b": 2, "c": 3}"#).value == nil)
    }

    @Test func itIsExportedAndGeneratedAsAnObjectNotAsAnyValue() throws {
        let exported = Schema.jsonObject().jsonSchema()
        #expect(exported.object?["type"] == "object", "a custom check on json() would export as {}")
        for seed in 0..<30 {
            let sample = try Schema.jsonObject().generator.sample(seed: UInt64(seed))
            guard case .object = sample.document else {
                fail("seed \(seed) made \(sample.document)")
                continue
            }
        }
    }

    @Test func itPassesItsOwnSuite() {
        let report = SchemaSuite(Schema.jsonObject(), equating: { $0 == $1 }).report(seed: 1, cases: 60)
        #expect(report.isClean, "\(report)")
    }

    @Test(.failureMode("design/06", "the text repeats a key and the options accept it"))
    func aRepeatAcceptedByTheParseOptionsIsAWarningAtTheRepeatNeverSilent() throws {
        var options = DecodeOptions.lenient
        options.parse.duplicateKeys = .lastWins
        let text = "{\n  \"a\": 1,\n  \"b\": 2,\n  \"a\": 3\n}"
        let decoded = Schema.jsonObject().decodeReporting(text, options: options)
        #expect(decoded.value == json(#"{"a": 3, "b": 2}"#), "the last one, in the first one's place")
        let issue = try #require(decoded.issues.first)
        #expect(decoded.issues.count == 1)
        #expect(issue.severity == .warning)
        #expect(issue.code == .repeatedKey)
        #expect(issue.path == at("a"))
        #expect(issue.source?.start.line == 4)
        #expect(issue.source?.start.column == 3)
        #expect(issue.parameters["firstLine"]?.number?.lexeme == "2")
        #expect(issue.parameters["firstColumn"]?.number?.lexeme == "3")
        #expect(issue.description == "4:3 $.a: warning: `a` is set more than once (first at line 2, column 3); the last one is used")

        var noted = issue
        noted.parameters["note"] = "the next save writes only that one"
        #expect(noted.message.hasSuffix("the last one is used; the next save writes only that one"))
    }

    @Test func aRepeatTheOptionsRefuseIsTheParsersErrorAndNoWarning() throws {
        let decoded = Schema.jsonObject().decodeReporting(#"{"a": 1, "a": 2}"#, options: .lenient)
        #expect(decoded.value == nil)
        let issue = try #require(decoded.issues.first)
        #expect(issue.code == .parseError)
        #expect(issue.parseCode == .duplicateKey)
    }

    @Test func theParsersCodeIsATypedAccessorNotAParameterToDigOut() throws {
        let notUTF8 = Schema.jsonObject().decodeReporting([UInt8]("{\"a\": \"".utf8) + [0xFF, 0xFE] + [UInt8]("\"}".utf8))
        #expect(notUTF8.issues.first?.parseCode == .invalidUTF8)
        #expect(Schema.jsonObject().decodeReporting("[1]").issues.first?.parseCode == nil, "a shape problem is not a parse problem")
        #expect(Schema.jsonObject().decodeReporting("{").issues.first?.parseCode == .unexpectedEnd)
    }
}
