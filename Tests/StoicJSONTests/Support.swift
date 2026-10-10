import StoicJSON
import Testing

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

/// The outcome of a parse, without typed-throws ceremony at every call site.
enum Outcome {
    case value(JSONValue)
    case failure(JSONParseError)

    var value: JSONValue? {
        if case .value(let value) = self { return value }
        return nil
    }

    var error: JSONParseError? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

func parse(_ bytes: [UInt8], _ options: JSONParseOptions = .strict) -> Outcome {
    do throws(JSONParseError) {
        return .value(try JSONValue(parsing: bytes, options: options))
    } catch {
        return .failure(error)
    }
}

func parse(_ text: String, _ options: JSONParseOptions = .strict) -> Outcome {
    parse(Array(text.utf8), options)
}

func parseDocument(_ text: String, _ options: JSONParseOptions = .strict) -> JSONDocument? {
    do throws(JSONParseError) {
        return try JSONDocument(parsing: text, options: options)
    } catch {
        Issue.record("unexpected parse failure: \(error)")
        return nil
    }
}

/// A named input, so a table of hundreds of cases reports which one failed.
struct InputCase: Sendable, CustomTestStringConvertible {
    var name: String
    var bytes: [UInt8]
    var testDescription: String { name }

    init(_ name: String, _ text: String) {
        self.name = name
        bytes = Array(text.utf8)
    }

    init(_ name: String, bytes: [UInt8]) {
        self.name = name
        self.bytes = bytes
    }
}

extension JSONObject {
    var keyList: [String] { map(\.key) }
}
