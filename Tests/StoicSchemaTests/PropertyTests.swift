import StoicJSON
import Testing

@testable import StoicSchema

/// How many random settings each property is checked on, and the seeds that
/// make a failure reproducible: a failing case names its seed.
private let cases = 400

@Suite("Properties of generated settings")
struct PropertyTests {
    @Test func theGeneratorOnlyMakesValidSettings() {
        for seed in 0..<UInt64(cases) {
            var gen = Gen(seed: seed)
            let settings = gen.settings()
            #expect(Settings.schema.validate(settings).isEmpty, "seed \(seed)")
        }
    }

    @Test func fullEncodingRoundTrips() {
        for seed in 0..<UInt64(cases) {
            var gen = Gen(seed: seed)
            let settings = gen.settings()
            let text = Settings.schema.encode(settings, style: .full).encodedString()
            let back = Settings.schema.decodeReporting(text)
            #expect(back.value == settings, "seed \(seed)")
            // The only thing a valid document may draw is the deprecation
            // notice for a deprecated field that carries a value.
            let expected = settings.legacyMode ? 1 : 0
            #expect(back.issues.count == expected, "seed \(seed): \(back.issues)")
            #expect(back.errors.isEmpty, "seed \(seed)")
        }
    }

    @Test func prettyAndCanonicalTextDecodeToTheSameValue() {
        for seed in 0..<UInt64(cases / 4) {
            var gen = Gen(seed: seed)
            let settings = gen.settings()
            let encoded = Settings.schema.encode(settings)
            let pretty = Settings.schema.decodeReporting(encoded.encodedString(style: .pretty())).value
            let canonical = Settings.schema.decodeReporting(encoded.encodedString(style: .canonical)).value
            #expect(pretty == settings, "seed \(seed)")
            #expect(canonical == settings, "seed \(seed)")
        }
    }

    @Test func sparseEncodingIsAFixedPoint() {
        for style in [EncodeStyle.sparse, .sparse(includeSecrets: true)] {
            for seed in 0..<UInt64(cases) {
                var gen = Gen(seed: seed)
                let settings = gen.settings()
                let once = Settings.schema.encode(settings, style: style)
                let decoded = Settings.schema.decodeReporting(once.encodedString())
                #expect(decoded.value != nil, "seed \(seed)")
                guard let value = decoded.value else { continue }
                #expect(Settings.schema.encode(value, style: style) == once, "seed \(seed)")
            }
        }
    }

    @Test func sparseWithSecretsRoundTripsAndWithoutLosesOnlyTheSecret() {
        for seed in 0..<UInt64(cases) {
            var gen = Gen(seed: seed)
            let settings = gen.settings()
            let withSecrets = Settings.schema.encode(settings, style: .sparse(includeSecrets: true))
            #expect(Settings.schema.decodeReporting(withSecrets.encodedString()).value == settings, "seed \(seed)")
            let without = Settings.schema.encode(settings, style: .sparse)
            var expected = settings
            expected.apiToken = Settings().apiToken
            #expect(Settings.schema.decodeReporting(without.encodedString()).value == expected, "seed \(seed)")
        }
    }

    @Test func sparseOutputNeverRepeatsADefault() {
        for seed in 0..<UInt64(cases) {
            var gen = Gen(seed: seed)
            let sparse = Settings.schema.encode(gen.settings(), style: .sparse(includeSecrets: true))
            let defaults = Settings.schema.encode(Settings())
            for member in sparse.object ?? JSONObject() {
                #expect(defaults.object?[member.key] != member.value, "seed \(seed): \(member.key) is a default")
            }
        }
    }

    @Test func sparseIsNoLargerThanFull() {
        for seed in 0..<UInt64(cases / 4) {
            var gen = Gen(seed: seed)
            let settings = gen.settings()
            let sparse = Settings.schema.encode(settings, style: .sparse(includeSecrets: true)).encodedString().utf8.count
            let full = Settings.schema.encode(settings, style: .full).encodedString().utf8.count
            #expect(sparse <= full, "seed \(seed)")
        }
    }

    @Test func positionsPointAtTheTextAtEveryDepth() {
        // Corrupt one value in a generated document and check that the issue's
        // range covers exactly that text.
        for seed in 0..<UInt64(cases / 4) {
            var gen = Gen(seed: seed)
            var document = Settings.schema.encode(gen.settings(), style: .full)
            guard var object = document.object else { continue }
            object["maxHistory"] = .number(JSONNumber(-1 - gen.int(0...50)))
            document = .object(object)
            let text = document.encodedString(style: .pretty())
            let result = Settings.schema.decodeReporting(text)
            guard let issue = result.errors.first, let source = issue.source,
                let parsed = try? JSONDocument(parsing: text)
            else {
                #expect(Bool(false), "seed \(seed): expected one error")
                continue
            }
            #expect(result.errors.count == 1, "seed \(seed)")
            #expect(issue.path.description == "$.maxHistory", "seed \(seed)")
            #expect(parsed.text(in: source) == object["maxHistory"]?.encodedString(), "seed \(seed)")
        }
    }
}
