import StoicJSON
import StoicSchema
import StoicTesting
import Testing

/// One entry of a feed.
struct Entry: Sendable, Equatable {
    var name: String
    var size: Int

    static let schema = Schema.object(Entry.self) { f in
        let name = f.field("name", \.name, .string(), doc: "A name.")
        let size = f.field("size", \.size, .int(.range(0...100)), doc: "A size.")
        return f.build { v in Entry(name: v[name], size: v[size]) }
    }
}

/// A response in which one bad element must not cost the others.
struct Feed: Sendable, Equatable {
    var ids: [Int]
    var entries: [Entry]
    var strict: [Int]
    var pair: [Int]

    static let schema = Schema.object(Feed.self) { f in
        let ids = f.field("ids", \.ids, .lossyArray(of: .int()), default: [], doc: "Identifiers.")
        let entries = f.field("entries", \.entries, .lossyArray(of: Entry.schema), default: [], doc: "Entries.")
        let strict = f.field("strict", \.strict, .array(of: .int()), default: [], doc: "A control.")
        let pair = f.field("pair", \.pair, .lossyArray(of: .int(), .count(2...3), .unique), default: [1, 2], doc: "Two or three.")
        return f.build { v in Feed(ids: v[ids], entries: v[entries], strict: v[strict], pair: v[pair]) }
    }
}

@Suite("Lossy arrays")
struct LossyArrayTests {
    @Test(.failureMode("design/06", "an element of a lossy array is invalid"))
    func invalidElementsAreDroppedWithAWarningEach() {
        let decoded = Feed.schema.decode(["ids": [1, "two", 3, .null, 5]])
        #expect(decoded.value?.ids == [1, 3, 5])
        #expect(decoded.errors.isEmpty)
        #expect(decoded.warnings.map { "\($0.path) \($0.code)" } == ["$.ids[1] dropped_element", "$.ids[3] dropped_element"])
        let first = decoded.warnings[0]
        #expect(first.parameters["index"]?.number?.lexeme == "1")
        #expect(first.parameters["reason"]?.string?.isEmpty == false)
        #expect(first.message.hasPrefix("dropped the element at index 1, which is invalid: "))
    }

    @Test func anElementWithSeveralProblemsIsOneWarning() {
        let decoded = Feed.schema.decode([
            "entries": [["name": "a", "size": 1], ["name": 5, "size": 500], ["size": 2], ["name": "d", "size": 4]]
        ])
        #expect(decoded.value?.entries == [Entry(name: "a", size: 1), Entry(name: "d", size: 4)])
        #expect(decoded.issues.map { "\($0.severity) \($0.path) \($0.code)" } == [
            "warning $.entries[1] dropped_element", "warning $.entries[2] dropped_element",
        ])
    }

    @Test func everythingElseIsStillReported() {
        let decoded = Feed.schema.decode(["ids": [1, "x"], "strict": [1, "y"], "entries": 3])
        #expect(decoded.value == nil)
        #expect(
            decoded.issues.map { "\($0.severity) \($0.path) \($0.code)" } == [
                "warning $.ids[1] dropped_element", "error $.entries type_mismatch", "error $.strict[1] type_mismatch",
            ])
    }

    @Test func theArraysOwnRulesApplyToWhatIsKept() {
        let few = Feed.schema.decode(["pair": [1, "x"]])
        #expect(few.value == nil)
        #expect(few.issues.map { "\($0.severity) \($0.path) \($0.code)" } == ["warning $.pair[1] dropped_element", "error $.pair too_few"])
        let repeated = Feed.schema.decode(["pair": [1, 1, "x", 2]])
        #expect(repeated.errors.map(\.code) == [.notUnique])
        #expect(Feed.schema.decode(["pair": [1, "x", 2]]).value?.pair == [1, 2])
    }

    @Test func leniencyChangesNothingAboutIt() {
        let decoded = Feed.schema.decode(["ids": [1, "x"]], options: .lenient)
        #expect(decoded.value?.ids == [1])
        #expect(decoded.repairs.isEmpty)
        #expect(decoded.warnings.map(\.code) == [.droppedElement])
    }

    @Test func aValueThatIsNotAnArrayIsStillAMismatch() {
        let decoded = Schema<[Int]>.lossyArray(of: .int()).decode(["a": 1])
        #expect(decoded.issues.map(\.code) == [.typeMismatch])
    }

    @Test func itWritesLikeAnArray() {
        let feed = Feed(ids: [1, 2], entries: [Entry(name: "a", size: 1)], strict: [], pair: [1, 2])
        let written = Feed.schema.encode(feed)
        #expect(written.object?["ids"] == [1, 2])
        #expect(Feed.schema.decode(written).value == feed)
    }

    @Test func theExportSaysSoAndKeepsTheElementSchema() {
        let exported = Schema<[Int]>.lossyArray(of: .int(.range(0...9))).jsonSchema()
        #expect(exported.object?["type"] == "array")
        #expect(exported.object?["x-stoic-lossy"] == true)
        #expect(exported.object?["items"]?.object?["maximum"] != nil)
    }

    @Test func theGeneratorBreaksElementsAndExpectsTheWarning() throws {
        let schema = Schema<[Int]>.lossyArray(of: .int(.range(0...9)), .count(1...5))
        let mutations = schema.generator.mutations(of: [1, 2, 3], seed: 1)
        let tolerated = mutations.filter(\.isTolerated)
        #expect(!tolerated.isEmpty)
        for mutation in tolerated {
            #expect(mutation.expected.map(\.code) == [.droppedElement])
            #expect(mutation.expected.allSatisfy { $0.severity == .warning })
            #expect(schema.decode(mutation.document).warnings.map(\.code) == [.droppedElement])
        }
        #expect(mutations.contains { $0.kind == .tooMany })
    }

    @Test func theSuiteIsClean() {
        let report = SchemaSuite(Feed.schema).report(seed: 6, cases: 150)
        #expect(report.isClean, "\(report)")
        #expect(report.tally[.mutations]?.runs ?? 0 > 0)
    }
}
