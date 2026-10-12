#if STOIC_MACROS
import StoicJSON
import StoicMacros
import StoicSchema
import StoicSchemaTesting
import Testing

/// A line of a feed.
@Schema
struct Line: Equatable {
    /// The text.
    @Length(1...20) var text: String = "x"
}

/// A response that survives bad elements.
@Schema(unknownKeys: .ignore)
struct Page: Equatable {
    /// Identifiers.
    @Lossy @Range(0...9) var ids: [Int] = []
    /// Lines.
    @Lossy @Count(...4) var lines: [Line] = []
    /// A maybe.
    @Lossy var maybe: [String]? = nil
    /// A control.
    var strict: [Int] = []
}

extension Page {
    static let byHand = Schema.object(
        Page.self, default: Page(), unknownKeys: .ignore, doc: "A response that survives bad elements."
    ) {
        Field("ids", \.ids, .lossyArray(of: .int(.range(0...9))), doc: "Identifiers.")
        Field("lines", \.lines, .lossyArray(of: Line.schema, .count(...4)), doc: "Lines.")
        Field("maybe", \.maybe, .optional(.lossyArray(of: .string())), doc: "A maybe.")
        Field("strict", \.strict, .array(of: .int()), doc: "A control.")
    }
}

@Suite("@Schema: lossy arrays")
struct LossyUsageTests {
    @Test func itIsTheSchemaWrittenByHand() {
        expectEquivalent(Page.schema, Page.byHand)
    }

    @Test func badElementsAreDroppedWithAWarning() {
        let decoded = Page.schema.decode(["ids": [1, 20, 3], "lines": [["text": ""], ["text": "ok"]], "maybe": ["a", 2]])
        #expect(decoded.value == Page(ids: [1, 3], lines: [Line(text: "ok")], maybe: ["a"], strict: []))
        #expect(decoded.errors.isEmpty)
        #expect(decoded.warnings.map { "\($0.path) \($0.code)" } == [
            "$.ids[1] dropped_element", "$.lines[0] dropped_element", "$.maybe[1] dropped_element",
        ])
    }

    @Test func aPlainArrayStillFails() {
        let decoded = Page.schema.decode(["strict": [1, "x"]])
        #expect(decoded.value == nil)
        #expect(decoded.errors.map(\.code) == [.typeMismatch])
    }

    @Test func theSuiteIsClean() {
        let report = SchemaSuite(Page.schema).report(seed: 9, cases: 120)
        #expect(report.isClean, "\(report)")
    }
}
#endif
