/// How ``JSONValue/encoded(style:)`` lays JSON out.
public enum JSONEncodingStyle: Sendable, Hashable {
    /// For hashing, signing and stable diffs: no whitespace, object members
    /// sorted by the UTF-16 code units of their keys, numbers in canonical
    /// form, strings with the minimal escapes.
    ///
    /// This follows RFC 8785 (JSON Canonicalization Scheme) wherever that
    /// document has an answer. It differs in one place on purpose: RFC 8785
    /// formats every number through an IEEE 754 double, which would round
    /// `9007199254740993` to `9007199254740992`. Here a number a `Double`
    /// holds exactly gets RFC 8785's text, and any other number keeps all
    /// its digits (see ``JSONNumber/canonicalLexeme``). Canonical output
    /// is a fixed point: parsing it and encoding again gives the same bytes.
    case canonical

    /// Source order and each number's own spelling, no whitespace. The
    /// smallest faithful rendering.
    case compact

    /// Source order and each number's own spelling, one member or element
    /// per line, nested containers indented by `indent` spaces. Empty
    /// containers stay on one line (`[]`, `{}`).
    case pretty(indent: Int = 2)
}

extension JSONValue {
    /// The value as UTF-8 JSON text.
    ///
    /// Every style produces text that parses back to an equal value. Strings
    /// are written with the escapes JSON requires and nothing more: `"`, `\`
    /// and control characters below U+0020 (short forms for `\b \t \n \f \r`,
    /// lowercase `\u00xx` for the rest). Everything else, including non-ASCII
    /// text and U+2028, is written as itself in UTF-8.
    public func encoded(style: JSONEncodingStyle = .canonical) -> [UInt8] {
        var writer = JSONWriter(style: style)
        writer.write(self, depth: 0)
        return writer.output
    }

    /// ``encoded(style:)`` as a `String`.
    public func encodedString(style: JSONEncodingStyle = .canonical) -> String {
        String(decoding: encoded(style: style), as: UTF8.self)
    }
}

/// Writes JSON text.
///
/// Recursive over the value's depth. A parsed value is at most as deep as
/// ``JSONParseOptions/maxDepth``; a value assembled in code is the caller's
/// to keep reasonably shallow.
struct JSONWriter {
    private let style: JSONEncodingStyle
    private let indent: Int
    var output: [UInt8] = []

    init(style: JSONEncodingStyle) {
        self.style = style
        if case .pretty(let indent) = style { self.indent = max(indent, 0) } else { indent = 0 }
    }

    private var isPretty: Bool {
        if case .pretty = style { return true }
        return false
    }

    private var isCanonical: Bool {
        if case .canonical = style { return true }
        return false
    }

    mutating func write(_ value: JSONValue, depth: Int) {
        switch value {
        case .null:
            output.append(contentsOf: "null".utf8)
        case .bool(let value):
            output.append(contentsOf: (value ? "true" : "false").utf8)
        case .number(let number):
            output.append(contentsOf: (isCanonical ? number.canonicalLexeme : number.lexeme).utf8)
        case .string(let string):
            Self.appendQuoted(string, to: &output)
        case .array(let elements):
            writeArray(elements, depth: depth)
        case .object(let object):
            writeObject(object, depth: depth)
        }
    }

    private mutating func writeArray(_ elements: [JSONValue], depth: Int) {
        guard !elements.isEmpty else {
            output.append(contentsOf: "[]".utf8)
            return
        }
        output.append(UInt8(ascii: "["))
        for (position, element) in elements.enumerated() {
            if position > 0 { output.append(UInt8(ascii: ",")) }
            newline(depth: depth + 1)
            write(element, depth: depth + 1)
        }
        newline(depth: depth)
        output.append(UInt8(ascii: "]"))
    }

    private mutating func writeObject(_ object: JSONObject, depth: Int) {
        guard !object.isEmpty else {
            output.append(contentsOf: "{}".utf8)
            return
        }
        var members = Array(object)
        if isCanonical {
            // RFC 8785 sorts by UTF-16 code units, which differs from UTF-8
            // byte order for code points above U+FFFF versus U+E000...U+FFFF.
            members.sort { $0.key.utf16.lexicographicallyPrecedes($1.key.utf16) }
        }
        output.append(UInt8(ascii: "{"))
        for (position, member) in members.enumerated() {
            if position > 0 { output.append(UInt8(ascii: ",")) }
            newline(depth: depth + 1)
            Self.appendQuoted(member.key, to: &output)
            output.append(UInt8(ascii: ":"))
            if isPretty { output.append(UInt8(ascii: " ")) }
            write(member.value, depth: depth + 1)
        }
        newline(depth: depth)
        output.append(UInt8(ascii: "}"))
    }

    private mutating func newline(depth: Int) {
        guard isPretty else { return }
        output.append(UInt8(ascii: "\n"))
        output.append(contentsOf: repeatElement(UInt8(ascii: " "), count: indent * depth))
    }

    // MARK: Strings

    private static let hexDigits = Array("0123456789abcdef".utf8)

    static func appendQuoted(_ string: String, to output: inout [UInt8]) {
        output.append(UInt8(ascii: "\""))
        for byte in string.utf8 {
            switch byte {
            case UInt8(ascii: "\""): output.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\"")])
            case UInt8(ascii: "\\"): output.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\\")])
            case 0x08: output.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "b")])
            case 0x09: output.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "t")])
            case 0x0A: output.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "n")])
            case 0x0C: output.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "f")])
            case 0x0D: output.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "r")])
            case 0..<0x20:
                output.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "u"), 0x30, 0x30])
                output.append(hexDigits[Int(byte >> 4)])
                output.append(hexDigits[Int(byte & 0x0F)])
            default:
                output.append(byte)
            }
        }
        output.append(UInt8(ascii: "\""))
    }
}
