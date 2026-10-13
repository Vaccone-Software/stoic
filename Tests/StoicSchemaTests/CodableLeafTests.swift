import Foundation
import StoicJSON
import StoicSchema
import StoicTesting
import Testing

/// A type with a Codable conformance and no schema of its own.
struct Geo: Codable, Sendable, Equatable {
    var lat: Double
    var lon: Double
    var label: String?
}

/// A Codable type that refuses to be written.
struct Unwritable: Codable, Sendable, Equatable {
    var value = 1

    init() {}
    init(from decoder: any Decoder) throws { _ = try decoder.singleValueContainer() }
    func encode(to encoder: any Encoder) throws {
        throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "no"))
    }
}

/// A model whose Codable leaves can only ever be absent.
struct Bag: Sendable, Equatable {
    var name = ""
    var spot: Geo?
}

/// A model holding a Codable payload beside an ordinary field.
struct Place: Sendable, Equatable {
    var name: String
    var geo: Geo
    var spots: [Geo]

    static let schema = Schema.object(Place.self) { f in
        let name = f.field("name", \.name, .string(), doc: "A name.")
        let geo = f.field(
            "geo", \.geo, .codable(Geo.self, examples: [Geo(lat: 1.5, lon: -2, label: nil), Geo(lat: 0, lon: 0, label: "x")]),
            doc: "Where.")
        let spots = f.field("spots", \.spots, .array(of: .codable(Geo.self, examples: [Geo(lat: 3, lon: 4, label: nil)])), default: [], doc: "More.")
        return f.build { v in Place(name: v[name], geo: v[geo], spots: v[spots]) }
    }
}

@Suite("The Codable leaf")
struct CodableLeafTests {
    private let schema = Schema.codable(Geo.self)

    @Test func itDecodesAndEncodesThroughJSONDecoderAndEncoder() {
        let decoded = schema.decode(["lat": 1.5, "lon": -2, "label": "home"])
        #expect(decoded.value == Geo(lat: 1.5, lon: -2, label: "home"))
        #expect(decoded.issues.isEmpty)
        let written = schema.encode(Geo(lat: 1.5, lon: -2, label: nil))
        #expect(written.object?["lat"] == 1.5)
        #expect(written.object?["label"] == nil)
    }

    @Test(.failureMode("design/06", "a Codable leaf's value is refused by JSONDecoder"))
    func aFailureIsOneIssueWithTheDecodersReason() {
        let decoded = Place.schema.decode(["name": "n", "geo": ["lat": "north", "lon": 2], "spots": [["lat": 1], 5]])
        #expect(decoded.value == nil)
        #expect(
            decoded.issues.map { "\($0.path) \($0.code)" } == [
                "$.geo invalid_value", "$.spots[0] invalid_value", "$.spots[1] invalid_value",
            ])
        let message = decoded.issues[0].parameters["message"]?.string ?? ""
        #expect(message.contains("lat"))
        #expect(decoded.issues[1].message.contains("lon"))
    }

    @Test func numbersKeepTheirDigits() {
        let big = Schema.codable(Int64.self)
        #expect(big.decode(JSONValue.number(JSONNumber(Int64.max))).value == Int64.max)
    }

    @Test func aSecretKeepsTheReasonToItself() {
        let decoded = Schema.object(Place.self) { f in
            let name = f.field("name", \.name, .string(), doc: "A name.")
            let geo = f.field("geo", \.geo, .codable(Geo.self), doc: "Where.", secret: true)
            let spots = f.field("spots", \.spots, .array(of: .codable(Geo.self)), default: [], doc: "More.")
            return f.build { v in Place(name: v[name], geo: v[geo], spots: v[spots]) }
        }.decode(["name": "n", "geo": ["lat": "hunter2"]])
        #expect(decoded.issues.map(\.code) == [.invalidValue])
        #expect(decoded.issues[0].parameters["message"] == nil)
        #expect(!decoded.issues[0].description.contains("hunter2"))
    }

    @Test func theExportIsTheSchemaThatAcceptsAnything() {
        #expect(schema.jsonSchema().object?.map(\.key) == ["$schema"])  // and nothing else: any JSON value
        let geo = Place.schema.jsonSchema().object?["properties"]?.object?["geo"]
        #expect(geo?.object?.map(\.key) == ["description"])
        let place = Place.schema.jsonSchema()
        #expect(place.object?["properties"]?.object?["geo"]?.object?["description"]?.string == "Where.")
    }

    @Test func aValueThatCannotBeWrittenIsReportedByValidate() {
        let issues = Schema.codable(Unwritable.self).validate(Unwritable())
        #expect(issues.map(\.code) == [.invalidValue])
    }

    @Test func theDecoderAndEncoderCanBeConfigured() {
        let schema = Schema.codable(
            Date.self, decoding: { $0.dateDecodingStrategy = .secondsSince1970 },
            encoding: { $0.dateEncodingStrategy = .secondsSince1970 })
        #expect(schema.decode(1_714_566_600).value == Date(timeIntervalSince1970: 1_714_566_600))
        #expect(schema.encode(Date(timeIntervalSince1970: 60)) == 60)
    }

    @Test func aSchemaHoldingTheLeafPassesItsSuite() {
        let report = SchemaSuite(Place.schema).report(seed: 8, cases: 100)
        #expect(report.isClean, "\(report)")
    }

    // Row: SchemaSuite meets a Codable leaf that has no examples.
    @Test(.failureMode("design/06", "SchemaSuite meets a Codable leaf that has no examples"))
    func aSuiteOnALeafWithoutExamplesSaysSoInsteadOfPassingOrCrashing() {
        let bare = Schema.codable(Geo.self)
        let report = SchemaSuite(bare).report(seed: 1, cases: 20)
        #expect(!report.isClean, "a suite that checked nothing is not clean")
        #expect(report.skipped == 20)
        let messages = report.findings.map(\.message)
        #expect(messages.contains { $0.contains("Codable leaf with no examples") && $0.contains("$ (Geo)") && $0.contains("examples:") })
        #expect(messages.contains { $0.contains("no case could be generated") && $0.contains("$ (Geo) has no examples") })
        #expect(throws: SchemaSuiteFailure.self) { try SchemaSuite(bare).run(seed: 1, cases: 5) }
    }

    @Test func aLeafWithoutExamplesInsideAModelIsAWarningWhenTheRestCanStillBeChecked() {
        let schema = Schema.object(Bag.self, default: Bag()) {
            Field("name", \.name, .string(.length(0...10)), doc: "A name.")
            Field("spot", \.spot, .optional(.codable(Geo.self)), doc: "Maybe.")
        }
        let report = SchemaSuite(schema).report(seed: 2, cases: 20)
        #expect(report.isClean, "\(report)")
        #expect(report.findings.contains { $0.severity == .warning && $0.message.contains("Codable leaf with no examples") })
    }

    @Test func theExamplesAreWhatTheGeneratorUsesAndWhatTheyEncodeTo() throws {
        let leaf = Schema.codable(Geo.self, examples: [Geo(lat: 1, lon: 2, label: "x")])
        let samples = try leaf.generator.samples(count: 5, seed: 1)
        #expect(samples.allSatisfy { $0.value == Geo(lat: 1, lon: 2, label: "x") })
        #expect(SchemaSuite(leaf).report(seed: 1, cases: 20).isClean)
    }
}
