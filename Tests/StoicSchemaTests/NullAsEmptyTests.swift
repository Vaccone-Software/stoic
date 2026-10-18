import StoicJSON
import StoicSchemaTesting
import StoicTesting
import Testing

@testable import StoicSchema

/// A section of a file that a person may empty out by writing `null`.
struct Scroll: Sendable, Equatable {
    var speed = 1000.0
    var smooth = true

    static let schema = Schema.object(Scroll.self, default: Scroll()) {
        Field("speed", \.speed, .double(.range(200...4000)), doc: "Pixels per second.", unit: "px/s")
        Field("smooth", \.smooth, .bool, doc: "Whether scrolling eases.")
    }
}

struct Sections: Sendable, Equatable {
    var scroll = Scroll()
    var strictScroll = Scroll()

    static let schema = Schema.object(Sections.self, default: Sections()) {
        Field("scroll", \.scroll, Scroll.schema.readingNullAsEmpty(), doc: "Scrolling.")
        Field("strictScroll", \.strictScroll, Scroll.schema, doc: "Scrolling, strictly.")
    }
}

@Suite("An object read from null")
struct NullAsEmptyTests {
    @Test(.failureMode("design/06", "a section that may be null is null"))
    func nullIsAnEmptySectionWithNoIssue() {
        for options in [DecodeOptions.strict, .lenient] {
            let decoded = Sections.schema.decode(["scroll": .null], options: options)
            #expect(decoded.value == Sections())
            #expect(decoded.issues.isEmpty)
        }
    }

    @Test func aSectionThatDidNotAskStillRefusesNull() {
        let decoded = Sections.schema.decode(["strictScroll": .null])
        #expect(decoded.value == nil)
        #expect(decoded.errors.map(\.code) == [.typeMismatch])
        let lenient = Sections.schema.decode(["strictScroll": .null], options: .lenient)
        #expect(lenient.value == Sections())
        #expect(lenient.repairs.map(\.code) == [.typeMismatch])
    }

    @Test func thingsInsideAreAsStrictAsBefore() {
        #expect(Sections.schema.decode(["scroll": ["speed": .null]]).errors.map(\.code) == [.typeMismatch])
        #expect(Sections.schema.decode(["scroll": 3]).errors.map(\.code) == [.typeMismatch])
    }

    @Test func nothingRemembersTheNullOnEncoding() {
        #expect(Sections.schema.encode(Sections(), style: .sparse) == [:])
        let full = Sections.schema.encode(Sections(), style: .full)
        #expect(full.object?["scroll"] == ["speed": 1000, "smooth": true])
    }

    @Test func aFormBObjectReportsItsMissingKeysAsForAnEmptyObject() {
        let schema = Schema<Scroll>.object(Scroll.self) { f in
            let speed = f.field("speed", \.speed, .double())
            return f.build { v in Scroll(speed: v[speed]) }
        }.readingNullAsEmpty()
        let decoded = schema.decode(.null)
        #expect(decoded.errors.map(\.code) == [.missingKey])
    }

    @Test func theExportAdmitsNullForTheSectionOnly() throws {
        let properties = try #require(Sections.schema.jsonSchema().object?["properties"]?.object)
        #expect(properties["scroll"]?.object?["type"] == ["object", "null"])
        #expect(properties["strictScroll"]?.object?["type"] == "object")
    }

    @Test func theSuiteIsCleanAndNeverOffersNullAsAViolation() {
        let report = SchemaSuite(Sections.schema, equating: { $0 == $1 }).report(seed: 6, cases: 120)
        #expect(report.isClean, "\(report)")
        let generator = SchemaGenerator(Sections.schema)
        let sample = try? generator.sample(seed: 6)
        let mutations = sample.map { generator.mutations(of: $0.document, seed: 6) } ?? []
        #expect(!mutations.contains { $0.kind == .nullForNonNullable && $0.location == at("scroll") })
        #expect(mutations.contains { $0.kind == .nullForNonNullable && $0.location == at("strictScroll") })
    }

    @Test func positionsPointAtTheNullForAnIssueBelowIt() {
        let schema = Schema<Sections>.object(Sections.self, default: Sections()) {
            Field("scroll", \.scroll, Scroll.schema.readingNullAsEmpty(), doc: "Scrolling.")
        }
        // Nothing below a null can be wrong; a document with a null and a bad sibling points at the sibling.
        let decoded = schema.decodeReporting("{\n  \"scroll\": null,\n  \"zzz\": 1\n}", options: .lenient)
        #expect(decoded.issues.map(\.code) == [.unknownKey])
        #expect(decoded.issues.first?.source?.start.line == 3)
    }
}
