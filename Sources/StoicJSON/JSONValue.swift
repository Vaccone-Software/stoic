/// A JSON value.
///
/// Equality and hashing follow JSON's own notion of sameness rather than
/// Swift's defaults, in two places where the defaults would be a security
/// hazard:
///
/// - Strings compare by their Unicode scalars. Swift's `String ==` treats
///   `"é"` and `"e\u{301}"` as equal; JSON, and every other parser and
///   database, treats them as different. A validator that accepted one
///   where it had checked the other would be a parser differential.
/// - Objects ignore member order (see ``JSONObject``), because JSON objects
///   are unordered collections that happen to be written in some order.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(JSONNumber)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    // MARK: Equality

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case (.bool(let a), .bool(let b)): a == b
        case (.number(let a), .number(let b)): a == b
        case (.string(let a), .string(let b)): a.utf8.elementsEqual(b.utf8)
        case (.array(let a), .array(let b)): a == b
        case (.object(let a), .object(let b)): a == b
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null:
            hasher.combine(0 as UInt8)
        case .bool(let value):
            hasher.combine(1 as UInt8)
            hasher.combine(value)
        case .number(let value):
            hasher.combine(2 as UInt8)
            hasher.combine(value)
        case .string(let value):
            hasher.combine(3 as UInt8)
            ExactString(value).hash(into: &hasher)
        case .array(let value):
            hasher.combine(4 as UInt8)
            hasher.combine(value)
        case .object(let value):
            hasher.combine(5 as UInt8)
            hasher.combine(value)
        }
    }

    // MARK: Accessors

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var number: JSONNumber? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var object: JSONObject? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// The value a path points at, or `nil` if the path leaves the value.
    public func value(at path: JSONPath) -> JSONValue? {
        var current = self
        for component in path {
            switch (component, current) {
            case (.key(let key), .object(let object)):
                guard let next = object[key] else { return nil }
                current = next
            case (.index(let index), .array(let array)):
                guard array.indices.contains(index) else { return nil }
                current = array[index]
            default:
                return nil
            }
        }
        return current
    }

    /// A short name for the kind of value, for messages: `"null"`,
    /// `"boolean"`, `"number"`, `"string"`, `"array"`, `"object"`.
    public var kindName: String {
        switch self {
        case .null: "null"
        case .bool: "boolean"
        case .number: "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(JSONNumber(value)) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    /// A non-finite literal is a programmer error: JSON cannot spell it.
    public init(floatLiteral value: Double) {
        guard let number = JSONNumber(value) else {
            preconditionFailure("JSON cannot represent \(value)")
        }
        self = .number(number)
    }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    /// Later duplicates of a key replace earlier ones, as in ``JSONObject``.
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(JSONObject(elements.map { JSONObject.Member(key: $0.0, value: $0.1) }))
    }
}

// MARK: - Exact strings

/// A string that is equal only to a string with the same scalars.
///
/// Swift compares and hashes strings by canonical equivalence, which is
/// right for text and wrong for keys of an interchange format. This wrapper
/// compares and hashes the UTF-8 bytes. Hashing byte by byte is not the
/// fastest possible, and it needs no unsafe code; the parser's cost is
/// dominated by other things.
struct ExactString: Hashable, Sendable {
    var value: String

    init(_ value: String) { self.value = value }

    static func == (lhs: ExactString, rhs: ExactString) -> Bool {
        lhs.value.utf8.elementsEqual(rhs.value.utf8)
    }

    func hash(into hasher: inout Hasher) {
        var count = 0
        for byte in value.utf8 {
            hasher.combine(byte)
            count += 1
        }
        hasher.combine(count)
    }
}
