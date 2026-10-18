import StoicJSON
import StoicSchemaTesting
import StoicTesting
import Testing

@testable import StoicSchema

/// Per-app switches a person fills in by hand: one wrong line must not cost the table.
struct AppSwitches: Sendable, Equatable {
    var ignored: [String: Bool] = [:]
    var limits: [String: Int] = [:]
    var strict: [String: Bool] = [:]
    var documented: [String: Bool] = [:]

    static let schema = Schema.object(AppSwitches.self, default: AppSwitches()) {
        Field(
            "ignored", \.ignored,
            .lossyDictionary(of: .bool, valueDoc: "true to never record clips from this app"),
            doc: "Apps whose clips are not recorded.")
        Field("limits", \.limits, .lossyDictionary(of: .int(.range(0...9)), .count(0...4)), doc: "Limits per app.")
        Field("strict", \.strict, .dictionary(of: .bool), doc: "A control.")
        Field(
            "documented", \.documented, .dictionary(of: .bool, valueDoc: "true to opt in"), doc: "A documented table.")
    }
}

@Suite("Lossy dictionaries")
struct LossyDictionaryTests {
    @Test(.failureMode("design/06", "an entry of a lossy dictionary is invalid"))
    func aBadEntryIsDroppedWithAWarningAtItsOwnPath() {
        let decoded = AppSwitches.schema.decode([
            "ignored": ["com.a": true, "com.b": "yes", "com.c": false, "com.d": 7]
        ])
        #expect(decoded.value?.ignored == ["com.a": true, "com.c": false])
        #expect(decoded.errors.isEmpty)
        #expect(decoded.issues.map { "\($0.severity) \($0.path) \($0.code)" } == [
            "warning $.ignored[\"com.b\"] dropped_entry", "warning $.ignored[\"com.d\"] dropped_entry",
        ])
        let first = decoded.issues[0]
        #expect(first.parameters["key"]?.string == "com.b")
        #expect(first.parameters["reason"]?.string?.isEmpty == false)
        #expect(first.message.hasPrefix("dropped the entry `com.b`, which is invalid: "))
    }

    @Test func anEntryWithSeveralProblemsIsOneWarning() {
        let decoded = AppSwitches.schema.decode(["limits": ["a": 1, "b": -1, "c": 99, "d": 2]])
        #expect(decoded.value?.limits == ["a": 1, "d": 2])
        #expect(decoded.issues.map { "\($0.severity) \($0.path) \($0.code)" } == [
            "warning $.limits.b dropped_entry", "warning $.limits.c dropped_entry",
        ])
    }

    @Test func everythingElseIsStillReported() {
        let decoded = AppSwitches.schema.decode([
            "ignored": ["a": 1], "strict": ["b": "no"], "limits": 3,
        ])
        #expect(decoded.value == nil)
        #expect(decoded.issues.map { "\($0.severity) \($0.path) \($0.code)" } == [
            "warning $.ignored.a dropped_entry", "error $.limits type_mismatch", "error $.strict.b type_mismatch",
        ])
    }

    @Test func theTablesOwnRulesApplyToWhatIsKept() {
        let table = Schema<[String: Int]>.lossyDictionary(of: .int(), .count(1...4))
        let few = table.decode(["a": "x"])
        #expect(few.value == nil)
        #expect(few.issues.map { "\($0.severity) \($0.path) \($0.code)" } == [
            "warning $.a dropped_entry", "error $ too_few",
        ])
        let many = AppSwitches.schema.decode(["limits": ["a": 1, "b": 1, "c": 1, "d": 1, "e": 1, "f": "x"]])
        #expect(many.errors.map(\.code) == [.tooMany])
    }

    @Test func leniencyChangesNothingAboutIt() {
        let decoded = AppSwitches.schema.decode(["ignored": ["a": true, "b": 1]], options: .lenient)
        #expect(decoded.value?.ignored == ["a": true])
        #expect(decoded.repairs.isEmpty)
        #expect(decoded.warnings.map(\.code) == [.droppedEntry])
    }

    @Test func theStrictFormStillFailsTheWholeTable() {
        let strict = AppSwitches.schema.decode(["strict": ["a": true, "b": 1]], options: .lenient)
        #expect(strict.value?.strict == [:])
        #expect(strict.repairs.map(\.code) == [.typeMismatch])
    }

    @Test func positionsPointAtTheBadEntry() {
        let text = "{\n  \"ignored\": {\n    \"com.a\": true,\n    \"com.b\": 5\n  }\n}"
        let decoded = AppSwitches.schema.decodeReporting(text, options: .lenient)
        let issue = decoded.issues.first
        #expect(issue?.code == .droppedEntry)
        #expect(issue?.source?.start.line == 4)
        #expect(issue?.source?.start.column == 14)
    }

    @Test func aKeyWrittenTwoWaysThatSwiftReadsAsOneIsDroppedNotLost() {
        var object = JSONObject()
        object["\u{e9}"] = true
        object["e\u{301}"] = false
        let decoded = Schema<[String: Bool]>.lossyDictionary(of: .bool).decode(.object(object))
        #expect(decoded.value?.count == 1)
        #expect(decoded.warnings.map(\.code) == [.droppedEntry])
    }

    @Test func encodingIsTheStrictDictionarys() {
        let value = AppSwitches(ignored: ["b": true, "a": false])
        let json = AppSwitches.schema.encode(value, style: .sparse)
        #expect(json == ["ignored": ["a": false, "b": true]])
    }

    @Test func theExportDescribesTheValuesAndSaysItIsLossy() throws {
        let schema = AppSwitches.schema.jsonSchema()
        let properties = try #require(schema.object?["properties"]?.object)
        let ignored = try #require(properties["ignored"]?.object)
        #expect(ignored["x-stoic-lossy"]?.bool == true)
        #expect(ignored["type"]?.string == "object")
        #expect(ignored["description"]?.string == "Apps whose clips are not recorded.")
        let values = try #require(ignored["additionalProperties"]?.object)
        #expect(values["type"]?.string == "boolean")
        #expect(values["description"]?.string == "true to never record clips from this app")
        let plain = try #require(properties["documented"]?.object?["additionalProperties"]?.object)
        #expect(plain["description"]?.string == "true to opt in")
        #expect(plain["x-stoic-transform"] == nil)
    }

    @Test func documentedChangesNothingButTheDescription() throws {
        let documented = Schema<[Int]>.array(of: Schema<Int>.int(.range(0...9)).documented("A digit."))
        #expect(documented.decode([1, 2]).value == [1, 2])
        #expect(documented.decode([1, 20]).errors.map(\.code) == [.outOfRange])
        let items = try #require(documented.jsonSchema().object?["items"]?.object)
        #expect(items["description"]?.string == "A digit.")
        #expect(items["maximum"]?.number?.lexeme == "9")
    }

    @Test func theSuiteIsCleanAndNeedsNoExamples() {
        let report = SchemaSuite(AppSwitches.schema, equating: { $0 == $1 }).report(seed: 5, cases: 120)
        #expect(report.isClean, "\(report)")
        #expect(!report.warnings.contains { $0.message.contains("declares no examples") })
    }
}
