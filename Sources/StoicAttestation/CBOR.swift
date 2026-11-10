#if STOIC_ATTESTATION

/// A value of the CBOR subset App Attest's objects use (RFC 8949, major
/// types 0, 2, 3, 4 and 5).
indirect enum CBORValue: Sendable, Equatable {
    case unsigned(UInt64)
    case bytes([UInt8])
    case text(String)
    case array([CBORValue])
    case map(CBORMap)

    var bytes: [UInt8]? { if case .bytes(let value) = self { value } else { nil } }
    var text: String? { if case .text(let value) = self { value } else { nil } }
    var array: [CBORValue]? { if case .array(let value) = self { value } else { nil } }
    var map: CBORMap? { if case .map(let value) = self { value } else { nil } }
}

/// A map whose keys are text, each once, in the order written.
struct CBORMap: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        let key: String
        let value: CBORValue
    }

    let entries: [Entry]

    subscript(key: String) -> CBORValue? { entries.first { $0.key == key }?.value }

    /// The keys, as a set.
    var keys: Set<String> { Set(entries.map(\.key)) }
}

/// Reads one CBOR value from bytes, strictly (design/29, Building it).
///
/// It is total: every length is checked against the bytes remaining before
/// anything is sliced, arithmetic cannot overflow, and a malformed input is
/// a ``CBORFailure``, never a trap. It refuses everything outside the
/// subset, and every alternative form that could give one input two
/// readings: negative integers, tags, floats and simple values, indefinite
/// lengths, reserved additional information, an integer or length not in
/// its shortest form, map keys that are not text, duplicate keys, text that
/// is not UTF-8, nesting deeper than ``maxDepth``, more than ``maxItems``
/// in a container, input over ``maxInput``, and trailing bytes.
struct CBORReader {
    static let maxInput = 64 * 1024
    static let maxDepth = 4
    static let maxItems = 16

    private let bytes: [UInt8]
    private var offset = 0

    private init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// The one value `bytes` hold.
    static func read(_ bytes: [UInt8]) throws(CBORFailure) -> CBORValue {
        guard bytes.count <= maxInput else { throw CBORFailure("input over \(maxInput) bytes") }
        var reader = CBORReader(bytes)
        let value = try reader.value(depth: 0)
        guard reader.offset == bytes.count else { throw CBORFailure("trailing bytes after the value") }
        return value
    }

    private mutating func value(depth: Int) throws(CBORFailure) -> CBORValue {
        let initial = try byte()
        let major = initial >> 5
        let info = initial & 0x1F
        switch major {
        case 0:
            return .unsigned(try argument(info))
        case 2:
            return .bytes(try take(try length(info)))
        case 3:
            let raw = try take(try length(info))
            guard let text = String(validating: raw, as: UTF8.self) else { throw CBORFailure("text that is not UTF-8") }
            return .text(text)
        case 4:
            guard depth < Self.maxDepth else { throw CBORFailure("nesting deeper than \(Self.maxDepth)") }
            let count = try length(info)
            guard count <= Self.maxItems else { throw CBORFailure("an array of more than \(Self.maxItems) items") }
            var elements: [CBORValue] = []
            for _ in 0..<count { elements.append(try value(depth: depth + 1)) }
            return .array(elements)
        case 5:
            guard depth < Self.maxDepth else { throw CBORFailure("nesting deeper than \(Self.maxDepth)") }
            let count = try length(info)
            guard count <= Self.maxItems else { throw CBORFailure("a map of more than \(Self.maxItems) entries") }
            var entries: [CBORMap.Entry] = []
            var seen: Set<String> = []
            for _ in 0..<count {
                guard case .text(let key) = try value(depth: depth + 1) else { throw CBORFailure("a map key that is not text") }
                guard seen.insert(key).inserted else { throw CBORFailure("a duplicate map key") }
                entries.append(CBORMap.Entry(key: key, value: try value(depth: depth + 1)))
            }
            return .map(CBORMap(entries: entries))
        case 1:
            throw CBORFailure("a negative integer")
        case 6:
            throw CBORFailure("a tag")
        default:
            throw CBORFailure("a float or simple value")
        }
    }

    private mutating func byte() throws(CBORFailure) -> UInt8 {
        guard offset < bytes.count else { throw CBORFailure("the input ends inside a value") }
        defer { offset += 1 }
        return bytes[offset]
    }

    /// The argument of an initial byte, in its shortest form only.
    private mutating func argument(_ info: UInt8) throws(CBORFailure) -> UInt64 {
        let width: Int
        switch info {
        case 0..<24: return UInt64(info)
        case 24: width = 1
        case 25: width = 2
        case 26: width = 4
        case 27: width = 8
        case 31: throw CBORFailure("an indefinite length")
        default: throw CBORFailure("reserved additional information")
        }
        var value: UInt64 = 0
        for byte in try take(width) { value = value << 8 | UInt64(byte) }
        let shortest: UInt64 = switch width {
        case 1: 24
        case 2: 0x100
        case 4: 0x1_0000
        default: 0x1_0000_0000
        }
        guard value >= shortest else { throw CBORFailure("an argument not in its shortest form") }
        return value
    }

    /// A length, which must fit in what remains.
    private mutating func length(_ info: UInt8) throws(CBORFailure) -> Int {
        let value = try argument(info)
        guard value <= UInt64(bytes.count - offset) else { throw CBORFailure("a length past the end of the input") }
        return Int(value)
    }

    private mutating func take(_ count: Int) throws(CBORFailure) -> [UInt8] {
        guard count >= 0, count <= bytes.count - offset else { throw CBORFailure("the input ends inside a value") }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }
}

/// Why bytes are not a value of the subset: what was found.
struct CBORFailure: Error, Sendable, Equatable {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}
#endif
