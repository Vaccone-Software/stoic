import StoicJSON
import StoicSchema
import Testing

/// Swift Testing has an `Issue` of its own; inside this target the bare name
/// would be ambiguous, so tests say which one they mean.
typealias SchemaIssue = StoicSchema.Issue

/// A small deterministic generator (SplitMix64), so a failing property test
/// names a seed that reproduces it on any machine.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Parses JSON text for a test, failing the test (not crashing it) when the
/// text is malformed.
func json(_ text: String) -> JSONValue {
    do throws(JSONParseError) {
        return try JSONValue(parsing: text)
    } catch {
        Testing.Issue.record("test JSON does not parse: \(error)")
        return .null
    }
}

extension Collection where Element == SchemaIssue {
    /// `(path, code)` pairs, for asserting exactly which problems were found
    /// and where without restating their prose.
    var locations: [String] {
        map { "\($0.path) \($0.code)" }
    }

    var errorCount: Int { filter { $0.severity == .error }.count }
}

/// A path of object keys, `at("network", "port")` for `$.network.port`.
func at(_ keys: String...) -> JSONPath {
    JSONPath(keys.map { .key($0) })
}
