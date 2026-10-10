import StoicJSON
import Testing

@testable import StoicSchema

/// The decoder and the exported JSON Schema must agree on what is valid.
/// The decoder is checked against a separate, small validator (see
/// `JSONSchemaValidator`) on generated valid documents and on documents with one
/// minimal violation each.
@Suite("Decoder and export agree")
struct DifferentialTests {
    private let validator = JSONSchemaValidator(Settings.schema.jsonSchema())

    @Test func generatedValidDocumentsAreAcceptedByBoth() {
        for seed in 0..<UInt64(300) {
            var gen = Gen(seed: seed)
            for style in [EncodeStyle.full, .sparse(includeSecrets: true)] {
                let document = Settings.schema.encode(gen.settings(), style: style)
                #expect(validator.accepts(document), "seed \(seed): validator rejects \(document.encodedString())")
                #expect(Settings.schema.decode(document).errors.isEmpty, "seed \(seed)")
            }
        }
    }

    /// One document with one violation each. Where the schema allows a
    /// spelling the validator cannot know (respelt keys), the cases avoid it.
    private let violations: [(name: String, patch: String)] = [
        ("speed below", #"{"scrollSpeed": 199.999}"#),
        ("speed above", #"{"scrollSpeed": 4000.001}"#),
        ("speed string", #"{"scrollSpeed": "1200"}"#),
        ("speed null", #"{"scrollSpeed": null}"#),
        ("theme wrong", #"{"theme": "Dark"}"#),
        ("theme number", #"{"theme": 1}"#),
        ("token too long", #"{"apiToken": "\#(String(repeating: "x", count: 129))"}"#),
        ("token number", #"{"apiToken": 5}"#),
        ("history negative", #"{"maxHistory": -1}"#),
        ("history too big", #"{"maxHistory": 10001}"#),
        ("history fractional", #"{"maxHistory": 1.5}"#),
        ("history huge", #"{"maxHistory": 9223372036854775808}"#),
        ("title empty", #"{"windowTitle": ""}"#),
        ("title too long", #"{"windowTitle": "\#(String(repeating: "t", count: 65))"}"#),
        ("title null", #"{"windowTitle": null}"#),
        ("zoom low", #"{"zoom": 0.49}"#),
        ("zoom high", #"{"zoom": 5.01}"#),
        ("shortcut empty", #"{"shortcuts": {"a": ""}}"#),
        ("shortcut number", #"{"shortcuts": {"a": 1}}"#),
        ("shortcuts array", #"{"shortcuts": []}"#),
        ("legacy string", #"{"legacyMode": "yes"}"#),
        ("network scalar", #"{"network": 1}"#),
        ("port zero", #"{"network": {"port": 0}}"#),
        ("port high", #"{"network": {"port": 65536}}"#),
        ("port fractional", #"{"network": {"port": 80.5}}"#),
        ("timeout zero", #"{"network": {"timeoutSeconds": 0}}"#),
        ("timeout high", #"{"network": {"timeoutSeconds": 600.1}}"#),
        ("tls string", #"{"network": {"useTLS": "true"}}"#),
        ("hosts empty element", #"{"network": {"hosts": ["a", ""]}}"#),
        ("hosts duplicate", #"{"network": {"hosts": ["a", "b", "a"]}}"#),
        ("hosts too many", #"{"network": {"hosts": ["1","2","3","4","5","6","7","8","9"]}}"#),
        ("hosts non-string", #"{"network": {"hosts": [1]}}"#),
        ("hosts long element", #"{"network": {"hosts": ["\#(String(repeating: "h", count: 254))"]}}"#),
    ]

    private let acceptable: [(name: String, patch: String)] = [
        ("speed lower edge", #"{"scrollSpeed": 200}"#),
        ("speed upper edge", #"{"scrollSpeed": 4000.0}"#),
        ("history edges", #"{"maxHistory": 0}"#),
        ("history upper", #"{"maxHistory": 10000}"#),
        ("title edge", #"{"windowTitle": "x"}"#),
        ("zoom edges", #"{"zoom": 0.5}"#),
        ("port edges", #"{"network": {"port": 65535}}"#),
        ("timeout tiny", #"{"network": {"timeoutSeconds": 0.000001}}"#),
        ("hosts eight", #"{"network": {"hosts": ["1","2","3","4","5","6","7","8"]}}"#),
        ("hosts none", #"{"network": {"hosts": []}}"#),
        ("unknown key is only a warning", #"{"surprise": 1}"#),
    ]

    private func merged(_ patch: String) -> JSONValue {
        var document = Settings.schema.encode(Settings()).object ?? JSONObject()
        for member in json(patch).object ?? JSONObject() {
            if case .object(let nested)? = document[member.key], case .object(let incoming) = member.value {
                var combined = nested
                for inner in incoming { combined[inner.key] = inner.value }
                document[member.key] = .object(combined)
            } else {
                document[member.key] = member.value
            }
        }
        return .object(document)
    }

    @Test func eachViolationIsRejectedByBoth() {
        for (name, patch) in violations {
            let document = merged(patch)
            #expect(!validator.accepts(document), "\(name): validator accepted \(patch)")
            #expect(Settings.schema.decode(document).value == nil, "\(name): decoder accepted \(patch)")
            #expect(Settings.schema.decode(document).errors.count == 1, "\(name): expected exactly one error")
        }
    }

    @Test func eachBoundaryIsAcceptedByBoth() {
        for (name, patch) in acceptable {
            let document = merged(patch)
            #expect(validator.accepts(document), "\(name): validator rejected \(patch)")
            #expect(Settings.schema.decode(document).value != nil, "\(name): decoder rejected \(patch)")
        }
    }

    @Test func randomViolationsOfRandomDocumentsAgree() {
        // Take a valid generated document and replace one field by a value
        // that is wrong in a way the schema knows, then compare verdicts.
        let replacements: [(key: String, value: JSONValue)] = [
            ("scrollSpeed", 5), ("scrollSpeed", "fast"), ("theme", "nope"), ("maxHistory", 1.5),
            ("zoom", 0), ("shortcuts", 3), ("network", [:]), ("legacyMode", 0),
        ]
        for seed in 0..<UInt64(200) {
            var gen = Gen(seed: seed)
            var object = Settings.schema.encode(gen.settings()).object ?? JSONObject()
            let pick = replacements[gen.int(0...(replacements.count - 1))]
            object[pick.key] = pick.value
            let document = JSONValue.object(object)
            let decoded = Settings.schema.decode(document)
            #expect(validator.accepts(document) == (decoded.value != nil), "seed \(seed): \(pick.key)")
        }
    }
}
