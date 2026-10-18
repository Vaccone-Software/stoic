import StoicJSON
import StoicSchemaTesting
import StoicTesting
import Testing

@testable import StoicSchema

enum KeyMode: String, Sendable, CaseIterable, Equatable {
    case hyper, caps
}

struct Watch: Sendable, Equatable {
    var isEnabled = false
    var interval = 5

    static let schema = Schema.object(Watch.self, default: Watch()) {
        Field("isEnabled", \.isEnabled, .bool, doc: "Whether it watches.")
        Field("interval", \.interval, .int(.range(1...60)), doc: "Seconds between looks.")
    }
    .normalizing(.rename("enabled", to: "isEnabled"))
}

/// A file whose reader has always forgiven its past: renamed keys, a renamed value,
/// a registry that changed shape, and keys nobody reads any more.
struct Remapped: Sendable, Equatable {
    var searcher = "none"
    var mode = KeyMode.caps
    var observations = Watch()
    var profiles: [String: Bool] = [:]

    static let schema = Schema.object(Remapped.self, default: Remapped(), unknownKeys: .warn) {
        Field("searcher", \.searcher, .string(), doc: "The searcher.")
        Field("mode", \.mode, .enumeration(KeyMode.self), doc: "The mode.")
        Field("observations", \.observations, Watch.schema, doc: "Observation.")
        Field("profiles", \.profiles, .dictionary(of: .bool), doc: "Profiles by name.")
    }
    .normalizing(
        .rename("hyper", to: "searcher"),
        .mapEnum("mode", ["raw-hyper": "hyper"]),
        .custom(id: "profiles", description: "a list of names becomes a table") { document in
            guard case .object(var members) = document, case .array(let names)? = members["profiles"] else { return }
            var table = JSONObject()
            for case .string(let name) in names { table[name] = true }
            members["profiles"] = .object(table)
            document = .object(members)
        },
        retired: ["old-flag", "observations.legacy"])
}

@Suite("Normalizing a document on every read")
struct NormalizationTests {
    @Test(.failureMode("design/06", "a document is read that a schema's normalization rewrites"))
    func anOldSpellingIsReadAsTheNewWithNoIssue() {
        let decoded = Remapped.schema.decode([
            "hyper": "x", "mode": "raw-hyper", "observations": ["enabled": true],
            "profiles": ["a", "b"], "old-flag": 1, "observations.legacy": 2,
        ])
        #expect(decoded.value?.searcher == "x")
        #expect(decoded.value?.mode == .hyper)
        #expect(decoded.value?.observations.isEnabled == true)
        #expect(decoded.value?.profiles == ["a": true, "b": true])
        // "observations.legacy" is a top-level key spelt with a dot, not the path: it is unknown.
        #expect(decoded.issues.map { "\($0.severity) \($0.path) \($0.code)" } == [
            "warning $[\"observations.legacy\"] unknown_key"
        ])
    }

    @Test func theNewKeyWinsWhenBothAreThere() {
        let decoded = Remapped.schema.decode(["hyper": "old", "searcher": "new", "observations": ["enabled": true, "isEnabled": false]])
        #expect(decoded.value?.searcher == "new")
        #expect(decoded.value?.observations.isEnabled == false)
        #expect(decoded.issues.isEmpty)
    }

    @Test func aMappedValueIsLeftAloneOnceItIsTheNewSpelling() {
        #expect(Remapped.schema.decode(["mode": "hyper"]).value?.mode == .hyper)
        let bad = Remapped.schema.decode(["mode": "nope"])
        #expect(bad.errors.map(\.code) == [.notOneOf])
    }

    @Test func retiredPathsAreSilentAtAnyDepthAndAUnknownSiblingStillWarns() {
        let decoded = Remapped.schema.decode(["old-flag": true, "observations": ["legacy": 1, "interval": 9], "stray": 1])
        #expect(decoded.value?.observations.interval == 9)
        #expect(decoded.issues.map { "\($0.path) \($0.code)" } == ["$.stray unknown_key"])
    }

    @Test func aPathNestedInANestedObjectRetiresInsideIt() {
        let schema = Schema.object(Watch.self, default: Watch(), unknownKeys: .reject) {
            Field("isEnabled", \.isEnabled, .bool, doc: "x")
        }.normalizing(retired: ["deep.old.thing"])
        #expect(schema.decode(["deep": ["old": ["thing": 1]]]).issues.map(\.code) == [.unknownKey])
        #expect(schema.decode(["deep": ["old": ["thing": 1]]]).issues.first?.path.description == "$.deep")
        #expect(schema.decode(["isEnabled": true]).value?.isEnabled == true)
    }

    @Test func aNestedObjectNormalizesItsOwnPart() {
        let decoded = Remapped.schema.decode(["observations": ["enabled": true, "interval": 70]])
        #expect(decoded.value == nil)
        #expect(decoded.errors.map { "\($0.path) \($0.code)" } == ["$.observations.interval out_of_range"])
    }

    @Test func normalizationIsIdempotent() {
        let documents: [JSONValue] = [
            ["hyper": "x", "mode": "raw-hyper", "profiles": ["a"], "old-flag": 1, "observations": ["enabled": true, "legacy": 1]],
            ["hyper": "x", "searcher": "y"],
            ["profiles": ["a": true]],
            [:], 3, ["observations": [:]],
        ]
        for document in documents {
            let once = Remapped.schema.normalized(document)
            #expect(Remapped.schema.normalized(once) == once)
            #expect((try? Normalization([.rename("a", to: "b")]).applying(to: document)) != nil)
        }
        let once = Remapped.schema.normalized(documents[0])
        #expect(once == ["searcher": "x", "mode": "hyper", "profiles": ["a": true], "observations": ["isEnabled": true]])
    }

    @Test func normalizedLeavesWhatItDoesNotDescribeAlone() {
        let schema = Schema<[String: Remapped]>.dictionary(of: Remapped.schema)
        let once = schema.normalized(["a": ["hyper": "x"], "b": 3])
        #expect(once == ["a": ["searcher": "x"], "b": 3])
    }

    @Test func moveKeepsAnExistingTargetAndPrunes() throws {
        let moves = Normalization([.move("a.b", to: "c")])
        #expect(try moves.applying(to: ["a": ["b": 1]]) == ["c": 1])
        #expect(try moves.applying(to: ["a": ["b": 1], "c": 2]) == ["c": 2])
        #expect(try moves.applying(to: ["x": 1]) == ["x": 1])
        let others = Normalization([.delete("a"), .setIfAbsent("n", 5), .setIfAbsent("m.k", 1)])
        #expect(try others.applying(to: ["a": 1, "n": 7]) == ["n": 7, "m": ["k": 1]])
    }

    @Test func aCustomOperationThatFailsIsAnIssueAtTheObject() {
        let schema = Schema.object(Watch.self, default: Watch()) {
            Field("isEnabled", \.isEnabled, .bool, doc: "x")
        }.normalizing(.custom(id: "boom", description: "always fails") { _ throws(MigrationFailure) in throw MigrationFailure("no way") })
        let decoded = schema.decode([:])
        #expect(decoded.value == nil)
        #expect(decoded.issues.map { "\($0.path) \($0.code)" } == ["$ normalization_failed"])
        #expect(decoded.issues.first?.message == "normalizing the document failed: no way")
        // Not an object: the schema reports that, not the normalization.
        #expect(schema.decode(3).errors.map(\.code) == [.typeMismatch])
    }

    @Test func aMovedValueIsReportedWhereTheTextWroteIt() {
        let text = """
        {
          "hyper": 5,
          "mode": "caps"
        }
        """
        let decoded = Remapped.schema.decodeReporting(text, options: .strict)
        #expect(decoded.errors.map { "\($0.path) \($0.code)" } == ["$.searcher type_mismatch"])
        // The value is on line 2, under the key the file spelt.
        #expect(decoded.errors.first?.source?.start.line == 2)
        #expect(decoded.errors.first?.source?.start.column == 12)
    }

    @Test func positionsOfUntouchedNodesAreTheTextsOwn() {
        let text = """
        {
          "hyper": "x",
          "old-flag": true,
          "observations": {
            "enabled": true,
            "interval": 99
          },
          "stray": 1
        }
        """
        let decoded = Remapped.schema.decodeReporting(text, options: .lenient)
        let byPath = Dictionary(uniqueKeysWithValues: decoded.issues.map { ("\($0.path)", $0) })
        #expect(byPath["$.observations.interval"]?.source?.start.line == 6)
        #expect(byPath["$.observations.interval"]?.source?.start.column == 17)
        #expect(byPath["$.stray"]?.source?.start.line == 8)
        #expect(byPath["$.stray"]?.source?.start.column == 3)
    }

    @Test func aRenamedKeyHoldingABadValueIsFoundAtItsOldKey() {
        let text = "{\n  \"observations\": {\n    \"enabled\": \"yes\"\n  }\n}"
        let decoded = Remapped.schema.decodeReporting(text, options: .strict)
        #expect(decoded.errors.map { "\($0.path) \($0.code)" } == ["$.observations.isEnabled type_mismatch"])
        #expect(decoded.errors.first?.source?.start.line == 3)
        #expect(decoded.errors.first?.source?.start.column == 16)
    }

    @Test func theExportAndTheEncodingAreUnchanged() {
        let exported = Remapped.schema.jsonSchema().object?["properties"]?.object
        #expect(Set(exported?.keys ?? []) == ["searcher", "mode", "observations", "profiles"])
        #expect(Remapped.schema.encode(Remapped(searcher: "s"), style: .sparse) == ["searcher": "s"])
        guard case .object(let node) = Remapped.schema.node else {
            Testing.Issue.record("not an object")
            return
        }
        #expect(node.normalization?.retired == ["old-flag", "observations.legacy"])
        #expect(node.normalization?.operations.map(\.description).first == "rename hyper to searcher")
    }

    @Test func theSuiteIsClean() {
        let report = SchemaSuite(Remapped.schema, equating: { $0 == $1 }).report(seed: 7, cases: 80)
        #expect(report.isClean, "\(report)")
    }
}
