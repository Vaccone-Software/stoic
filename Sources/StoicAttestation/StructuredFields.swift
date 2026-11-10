#if STOIC_ATTESTATION
internal import Foundation

/// A bare item of the Structured Fields subset (RFC 8941) the App Attest
/// headers use: integers, strings, tokens, byte sequences and booleans. No
/// decimals, dates or display strings.
enum SFItem: Sendable, Equatable {
    case integer(Int64)
    case string(String)
    case token(String)
    case bytes([UInt8])
    case boolean(Bool)

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var token: String? { if case .token(let value) = self { value } else { nil } }
    var bytes: [UInt8]? { if case .bytes(let value) = self { value } else { nil } }
}

/// Parameters, in the order written, each key once.
struct SFParameters: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        let key: String
        let value: SFItem
    }

    var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }
    subscript(key: String) -> SFItem? { entries.first { $0.key == key }?.value }
}

/// A dictionary member's value: an item or an inner list, with parameters.
enum SFMember: Sendable, Equatable {
    case item(SFItem, SFParameters)
    case innerList([SFListItem], SFParameters)
}

struct SFListItem: Sendable, Equatable {
    let item: SFItem
    let parameters: SFParameters
}

/// A dictionary, in the order written, each key once.
struct SFDictionary: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        let key: String
        let member: SFMember
    }

    let entries: [Entry]

    subscript(key: String) -> SFMember? { entries.first { $0.key == key }?.member }
}

/// Parses the Structured Fields subset strictly (design/29, Building it):
/// header values over ``maxBytes`` are refused, and so is every form that
/// could give one value two readings. A duplicate dictionary key or
/// parameter, which RFC 8941 resolves by keeping the last, is refused here;
/// so is a byte sequence whose base64 is not canonical, and anything after
/// the value. It is total: no input traps.
struct SFParser {
    static let maxBytes = 16 * 1024
    static let maxMembers = 16
    static let maxParameters = 16

    private let bytes: [UInt8]
    private var offset = 0

    private init(_ text: String) {
        bytes = Array(text.utf8)
    }

    /// `text` as a dictionary.
    static func dictionary(_ text: String) throws(SFFailure) -> SFDictionary {
        guard text.utf8.count <= maxBytes else { throw SFFailure("a header over \(maxBytes) bytes") }
        var parser = SFParser(text)
        parser.skipSpaces()
        let dictionary = try parser.dictionary()
        parser.skipSpaces()
        guard parser.atEnd else { throw SFFailure("characters after the dictionary") }
        return dictionary
    }

    /// `text` as one item with its parameters.
    static func item(_ text: String) throws(SFFailure) -> (SFItem, SFParameters) {
        guard text.utf8.count <= maxBytes else { throw SFFailure("a header over \(maxBytes) bytes") }
        var parser = SFParser(text)
        parser.skipSpaces()
        let item = try parser.bareItem()
        let parameters = try parser.parameters()
        parser.skipSpaces()
        guard parser.atEnd else { throw SFFailure("characters after the item") }
        return (item, parameters)
    }

    private var atEnd: Bool { offset >= bytes.count }
    private var current: UInt8? { atEnd ? nil : bytes[offset] }

    private mutating func skipSpaces() {
        while current == 0x20 { offset += 1 }
    }

    private mutating func skipOWS() {
        while current == 0x20 || current == 0x09 { offset += 1 }
    }

    private mutating func dictionary() throws(SFFailure) -> SFDictionary {
        var entries: [SFDictionary.Entry] = []
        var seen: Set<String> = []
        while !atEnd {
            let key = try self.key()
            guard seen.insert(key).inserted else { throw SFFailure("a duplicate dictionary key") }
            let member: SFMember
            if current == 0x3D {  // "="
                offset += 1
                member = current == 0x28 ? try innerList() : .item(try bareItem(), try parameters())
            } else {
                member = .item(.boolean(true), try parameters())
            }
            entries.append(SFDictionary.Entry(key: key, member: member))
            guard entries.count <= Self.maxMembers else { throw SFFailure("more than \(Self.maxMembers) members") }
            skipOWS()
            if atEnd { break }
            guard current == 0x2C else { throw SFFailure("members not separated by a comma") }
            offset += 1
            skipOWS()
            guard !atEnd else { throw SFFailure("a trailing comma") }
        }
        return SFDictionary(entries: entries)
    }

    private mutating func innerList() throws(SFFailure) -> SFMember {
        offset += 1  // "("
        var items: [SFListItem] = []
        while true {
            skipSpaces()
            guard let byte = current else { throw SFFailure("an inner list that is not closed") }
            if byte == 0x29 {  // ")"
                offset += 1
                return .innerList(items, try parameters())
            }
            items.append(SFListItem(item: try bareItem(), parameters: try parameters()))
            guard items.count <= Self.maxMembers else { throw SFFailure("more than \(Self.maxMembers) items in a list") }
            guard current == 0x20 || current == 0x29 else { throw SFFailure("inner list items not separated by a space") }
        }
    }

    private mutating func parameters() throws(SFFailure) -> SFParameters {
        var parameters = SFParameters()
        var seen: Set<String> = []
        while current == 0x3B {  // ";"
            offset += 1
            skipSpaces()
            let key = try self.key()
            guard seen.insert(key).inserted else { throw SFFailure("a duplicate parameter") }
            let value: SFItem
            if current == 0x3D {
                offset += 1
                value = try bareItem()
            } else {
                value = .boolean(true)
            }
            parameters.entries.append(SFParameters.Entry(key: key, value: value))
            guard parameters.entries.count <= Self.maxParameters else { throw SFFailure("more than \(Self.maxParameters) parameters") }
        }
        return parameters
    }

    /// `lcalpha / "*"` then `lcalpha / DIGIT / "_" / "-" / "." / "*"`.
    private mutating func key() throws(SFFailure) -> String {
        guard let first = current, Self.isLowercase(first) || first == 0x2A else { throw SFFailure("a key that does not start with a lower-case letter") }
        let start = offset
        while let byte = current, Self.isLowercase(byte) || Self.isDigit(byte) || [0x5F, 0x2D, 0x2E, 0x2A].contains(byte) { offset += 1 }
        return String(decoding: bytes[start..<offset], as: UTF8.self)
    }

    private mutating func bareItem() throws(SFFailure) -> SFItem {
        guard let byte = current else { throw SFFailure("a missing item") }
        switch byte {
        case 0x2D, 0x30...0x39: return try integer()
        case 0x22: return try string()
        case 0x3A: return try byteSequence()
        case 0x3F: return try boolean()
        case 0x2A, 0x41...0x5A, 0x61...0x7A: return token()
        default: throw SFFailure("an item of a kind this parser does not read")
        }
    }

    private mutating func integer() throws(SFFailure) -> SFItem {
        var negative = false
        if current == 0x2D {
            negative = true
            offset += 1
        }
        var value: Int64 = 0
        var digits = 0
        while let byte = current, Self.isDigit(byte) {
            digits += 1
            guard digits <= 15 else { throw SFFailure("an integer of more than 15 digits") }
            value = value * 10 + Int64(byte - 0x30)
            offset += 1
        }
        guard digits > 0 else { throw SFFailure("a sign without digits") }
        guard current != 0x2E else { throw SFFailure("a decimal") }
        return .integer(negative ? -value : value)
    }

    private mutating func string() throws(SFFailure) -> SFItem {
        offset += 1  // the opening quote
        var output: [UInt8] = []
        while let byte = current {
            offset += 1
            switch byte {
            case 0x5C:  // a backslash escapes only a quote or a backslash
                guard let next = current, next == 0x22 || next == 0x5C else { throw SFFailure("an escape other than \\\" or \\\\") }
                output.append(next)
                offset += 1
            case 0x22:
                return .string(String(decoding: output, as: UTF8.self))
            case 0x20...0x7E:
                output.append(byte)
            default:
                throw SFFailure("a string with a character outside visible ASCII")
            }
        }
        throw SFFailure("a string that is not closed")
    }

    private mutating func byteSequence() throws(SFFailure) -> SFItem {
        offset += 1  // ":"
        let start = offset
        while let byte = current, byte != 0x3A {
            guard Self.isBase64(byte) else { throw SFFailure("a byte sequence with a character outside base64") }
            offset += 1
        }
        guard current == 0x3A else { throw SFFailure("a byte sequence that is not closed") }
        let encoded = String(decoding: bytes[start..<offset], as: UTF8.self)
        offset += 1
        guard let decoded = Base64.canonical(encoded) else { throw SFFailure("a byte sequence whose base64 is not canonical") }
        return .bytes(decoded)
    }

    private mutating func boolean() throws(SFFailure) -> SFItem {
        offset += 1  // "?"
        guard let byte = current, byte == 0x30 || byte == 0x31 else { throw SFFailure("a boolean that is not ?0 or ?1") }
        offset += 1
        return .boolean(byte == 0x31)
    }

    private mutating func token() -> SFItem {
        let start = offset
        offset += 1
        while let byte = current, Self.isTokenCharacter(byte) { offset += 1 }
        return .token(String(decoding: bytes[start..<offset], as: UTF8.self))
    }

    private static func isLowercase(_ byte: UInt8) -> Bool { byte >= 0x61 && byte <= 0x7A }
    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

    private static func isBase64(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || isLowercase(byte) || isDigit(byte) || byte == 0x2B || byte == 0x2F || byte == 0x3D
    }

    /// RFC 9110's tchar, and ":" and "/".
    private static func isTokenCharacter(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || isLowercase(byte) || isDigit(byte)
            || "!#$%&'*+-.^_`|~:/".utf8.contains(byte)
    }
}

/// Why a header value is not of the subset.
struct SFFailure: Error, Sendable, Equatable {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

/// Standard base64 with padding, in its one canonical form.
enum Base64 {
    /// The bytes `text` encodes, if it is exactly how they encode: no
    /// whitespace, padding where it belongs, and unused bits zero. Anything
    /// else is `nil`, so one value has one spelling.
    static func canonical(_ text: String) -> [UInt8]? {
        guard let data = Data(base64Encoded: text), data.base64EncodedString() == text else { return nil }
        return Array(data)
    }

    static func encode(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
    }
}
#endif
