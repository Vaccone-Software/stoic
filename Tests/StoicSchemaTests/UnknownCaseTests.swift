import StoicJSON
import StoicSchema
import StoicTesting
import Testing

/// A closed set with a case for "something newer than this client".
enum Stage: String, CaseIterable, Sendable, Equatable {
    case draft, live, retired, unknown
}

/// The same with a number on the wire.
enum Level: Int, CaseIterable, Sendable, Equatable {
    case low = 1, high = 2, other = 0
}

/// A case that keeps what it did not understand.
enum Tier: Sendable, Equatable {
    case free, paid
    case unknown(String)

    static let schema = Schema.openEnumeration(
        Tier.self, cases: ["free", "paid"], fallback: "unknown",
        read: { raw in
            switch raw {
            case "free": .free
            case "paid": .paid
            default: .unknown(raw)
            }
        },
        write: { tier in
            switch tier {
            case .free: "free"
            case .paid: "paid"
            case .unknown(let raw): raw
            }
        })
}

/// An object holding all three, so a warning sits beside an error.
struct Listing: Sendable, Equatable {
    var stage: Stage
    var level: Level
    var tier: Tier
    var title: String

    static let schema = Schema.object(Listing.self) { f in
        let stage = f.field("stage", \.stage, .enumeration(Stage.self, unknownCase: .unknown), doc: "Where it is.")
        let level = f.field("level", \.level, .enumeration(Level.self, unknownCase: .other), doc: "How much.")
        let tier = f.field("tier", \.tier, Tier.schema, doc: "What is paid.")
        let title = f.field("title", \.title, .string(), doc: "A name.")
        return f.build { v in Listing(stage: v[stage], level: v[level], tier: v[tier], title: v[title]) }
    }
}

@Suite("Enumerations with an unknown case")
struct UnknownCaseTests {
    private let stage = Schema.enumeration(Stage.self, unknownCase: .unknown)

    @Test(.failureMode("design/06", "an enumeration with an unknown case meets a value it does not know"))
    func anUnknownStringIsReadAsTheUnknownCaseWithAWarning() {
        let decoded = stage.decode(JSONValue.string("archived"))
        #expect(decoded.value == .unknown)
        #expect(decoded.issues.count == 1)
        let issue = decoded.issues[0]
        #expect(issue.code == .unknownCase)
        #expect(issue.severity == .warning)
        #expect(issue.parameters["fallback"]?.string == "unknown")
        #expect(issue.actual == "\"archived\"")
        #expect(issue.message.contains("read as `unknown`"))
    }

    @Test func aKnownValueHasNoIssue() {
        let decoded = stage.decode(JSONValue.string("live"))
        #expect(decoded.value == .live)
        #expect(decoded.issues.isEmpty)
        #expect(stage.decode(JSONValue.string("unknown")).issues.isEmpty)
    }

    @Test func aWrongKindOfValueIsStillAnError() {
        let decoded = stage.decode(.number(JSONNumber(3)))
        #expect(decoded.value == nil)
        #expect(decoded.issues.map(\.code) == [.typeMismatch])
    }

    @Test func theNearestKnownValueIsSuggested() {
        #expect(stage.decode(JSONValue.string("lve")).issues.first?.suggestions == ["live"])
    }

    @Test func anIntegerEnumerationHasTheSameWayOut() {
        let schema = Schema.enumeration(Level.self, unknownCase: .other)
        let decoded = schema.decode(.number(JSONNumber(9)))
        #expect(decoded.value == .other)
        #expect(decoded.issues.map(\.code) == [.unknownCase])
        #expect(schema.decode(.number(JSONNumber(2))).value == .high)
        #expect(schema.decode(JSONValue.string("high")).issues.map(\.code) == [.typeMismatch])
        #expect(schema.decode(1.5).value == nil)
    }

    @Test func aCaseThatCarriesTheValueWritesItBack() {
        let decoded = Tier.schema.decode(JSONValue.string("enterprise"))
        #expect(decoded.value == .unknown("enterprise"))
        #expect(decoded.issues.map(\.code) == [.unknownCase])
        #expect(Tier.schema.encode(.unknown("enterprise")) == "enterprise")
        #expect(Tier.schema.encode(.paid) == "paid")
    }

    @Test func theWarningSurvivesAnErrorElsewhere() {
        let decoded = Listing.schema.decode(["stage": "archived", "level": 9, "tier": "gold"])
        #expect(decoded.value == nil)
        #expect(
            decoded.issues.map { "\($0.severity) \($0.path) \($0.code)" }.sorted() == [
                "error $.title missing_key", "warning $.level unknown_case", "warning $.stage unknown_case",
                "warning $.tier unknown_case",
            ])
    }

    @Test func theValueIsAcceptedAndOnlyWarnedAbout() {
        let decoded = Listing.schema.decode(["stage": "archived", "level": 1, "tier": "gold", "title": "x"])
        #expect(decoded.value == Listing(stage: .unknown, level: .low, tier: .unknown("gold"), title: "x"))
        #expect(decoded.issues.count == 2)
        #expect(decoded.errors.isEmpty)
    }

    @Test func theExportAcceptsAnyStringAndListsTheKnownOnes() throws {
        let export = stage.jsonSchema()
        #expect(export.object?["type"] == "string")
        #expect(export.object?["enum"] == nil)
        #expect(export.object?["examples"]?.array?.compactMap(\.string) == ["draft", "live", "retired", "unknown"])
        #expect(export.object?["x-stoic-transform"]?.object?["description"]?.string?.contains("any other string") == true)
    }

    @Test func theSchemasPassTheirSuites() {
        #expect(SchemaSuite(Listing.schema).report(seed: 4, cases: 120).isClean)
        #expect(SchemaSuite(Tier.schema).report(seed: 4, cases: 60).isClean)
    }
}
