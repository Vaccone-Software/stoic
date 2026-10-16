public import StoicJSON

/// The keys of a container whose names are not known until it is read.
struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// An `Encodable` carrier for a JSON tree, so that containers can hold one.
private struct JSONNode: Encodable {
    var value: JSONValue

    init(_ value: JSONValue) {
        self.value = value
    }

    func encode(to encoder: any Encoder) throws {
        try value.write(to: encoder)
    }
}

extension JSONValue {
    /// Reads whatever the decoder holds at its position into a JSON tree,
    /// by walking it with dynamic keys, so it works with any `Decoder`: a
    /// `JSONDecoder`, a `PropertyListDecoder`, one a test wrote.
    ///
    /// The decoder decides what it can say. A container that is not a
    /// dictionary is tried as an array and then as a single value, in that
    /// order. **Numbers** arrive as the decoder gives them, an `Int64`, a
    /// `UInt64` or a `Double`, tried in that order: the spelling in the
    /// source text is gone by the time a `Decoder` is asked (`1.0` is `1`
    /// to `JSONDecoder`, and digits past a `Double`'s precision are lost for
    /// a number that is not an integer), which is the price of working
    /// through `Decodable`. (A negative zero is read as an integer zero.)
    /// The schema's own text entry points keep the spelling. **Object members** arrive sorted by key, because a
    /// `Decoder` promises no order. **Repeated keys** never arrive: the
    /// decoder resolved them before it was asked (`JSONDecoder` keeps the
    /// first), so the refusal StoicJSON makes of a document with a repeated
    /// key cannot be made here.
    ///
    /// **Limits.** The walk enforces `limits`' `maxDepth`, `maxStringBytes`
    /// and `maxContainerCount`, as the parser would (it cannot see bytes, so
    /// not `maxBytes`), and fails with `DecodingError.dataCorrupted` naming
    /// the limit. It is iterative, with its own stack, so the depth of what
    /// the decoder holds decides how much memory it takes, never how much of
    /// the call stack: a recursive walk, on a thread's 512 KiB stack, was
    /// crashed by 250 levels of nesting under a key the schema did not even
    /// declare.
    public init(reading decoder: any Decoder, limits: JSONParseOptions = .strict) throws {
        var frames: [ReadingFrame] = []
        var next: (any Decoder)? = decoder
        var value: JSONValue?
        while true {
            if let opening = next {
                next = nil
                if let keyed = try? opening.container(keyedBy: DynamicKey.self) {
                    try Self.checkDepth(frames.count, of: opening, limits)
                    let keys = keyed.allKeys.sorted { $0.stringValue.utf8.lexicographicallyPrecedes($1.stringValue.utf8) }
                    try Self.checkCount(keys.count, of: opening, limits)
                    for key in keys { try Self.checkString(key.stringValue, of: opening, limits) }
                    frames.append(ReadingFrame(keyed: keyed, keys: keys))
                } else if let unkeyed = try? opening.unkeyedContainer() {
                    try Self.checkDepth(frames.count, of: opening, limits)
                    try Self.checkCount(unkeyed.count ?? 0, of: opening, limits)
                    frames.append(ReadingFrame(unkeyed: unkeyed))
                } else {
                    value = try Self.scalar(in: opening, limits)
                }
            }
            // A value just finished belongs to the frame below it; then that
            // frame either opens its next child or is finished itself.
            guard let frame = frames.last else {
                self = value ?? .null
                return
            }
            if let finished = value {
                frame.add(finished)
                value = nil
            }
            if let child = try frame.nextChild(limits) {
                next = child
            } else {
                value = frame.value
                frames.removeLast()
            }
        }
    }

    /// One scalar, tried as null, a boolean, a string and then a number.
    private static func scalar(in decoder: any Decoder, _ limits: JSONParseOptions) throws -> JSONValue {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            return .null
        } else if let value = try? single.decode(Bool.self) {
            return .bool(value)
        } else if let value = try? single.decode(String.self) {
            try checkString(value, of: decoder, limits)
            return .string(value)
        } else if let value = try? single.decode(Int64.self) {
            return .number(JSONNumber(value))
        } else if let value = try? single.decode(UInt64.self) {
            return .number(JSONNumber(value))
        } else if let value = try? single.decode(Double.self), let number = JSONNumber(value) {
            return .number(number)
        }
        throw DecodingError.typeMismatch(
            JSONValue.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "the decoder holds a value that is not null, a boolean, a string, a number, an array or a dictionary"
            ))
    }

    private static func checkDepth(_ open: Int, of decoder: any Decoder, _ limits: JSONParseOptions) throws {
        guard open >= limits.maxDepth else { return }
        throw beyond(decoder.codingPath, "nesting is deeper than \(limits.maxDepth) levels, the limit")
    }

    private static func checkCount(_ count: Int, of decoder: any Decoder, _ limits: JSONParseOptions) throws {
        guard count > limits.maxContainerCount else { return }
        throw beyond(decoder.codingPath, "a container has more than \(limits.maxContainerCount) elements, the limit")
    }

    private static func checkString(_ text: String, of decoder: any Decoder, _ limits: JSONParseOptions) throws {
        guard text.utf8.count > limits.maxStringBytes else { return }
        throw beyond(decoder.codingPath, "a string is longer than \(limits.maxStringBytes) bytes (UTF-8), the limit")
    }

    fileprivate static func beyond(_ codingPath: [any CodingKey], _ message: String) -> DecodingError {
        DecodingError.dataCorrupted(DecodingError.Context(codingPath: codingPath, debugDescription: message))
    }
}

/// An open container of ``JSONValue/init(reading:limits:)``'s walk: where it
/// is, and what it has read so far. A class, so the walk extends the members
/// in place instead of copying them each time a child finishes.
private final class ReadingFrame {
    private let keyed: KeyedDecodingContainer<DynamicKey>?
    private var unkeyed: (any UnkeyedDecodingContainer)?
    private let keys: [DynamicKey]
    /// The key of the child being read, for an object.
    private var position = 0
    private var object = JSONObject()
    private var items: [JSONValue] = []

    init(keyed: KeyedDecodingContainer<DynamicKey>, keys: [DynamicKey]) {
        self.keyed = keyed
        self.keys = keys
        unkeyed = nil
    }

    init(unkeyed: any UnkeyedDecodingContainer) {
        keyed = nil
        keys = []
        self.unkeyed = unkeyed
    }

    var value: JSONValue { keyed == nil ? .array(items) : .object(object) }

    func add(_ value: JSONValue) {
        if keyed == nil {
            items.append(value)
        } else {
            object[keys[position - 1].stringValue] = value
        }
    }

    /// A decoder for the next child, or `nil` when every child was read.
    func nextChild(_ limits: JSONParseOptions) throws -> (any Decoder)? {
        if let keyed {
            guard position < keys.count else { return nil }
            position += 1
            return try keyed.superDecoder(forKey: keys[position - 1])
        }
        guard var container = unkeyed, !container.isAtEnd else { return nil }
        // A container that did not say its count is counted as it is read.
        if items.count >= limits.maxContainerCount {
            throw JSONValue.beyond(
                container.codingPath, "a container has more than \(limits.maxContainerCount) elements, the limit")
        }
        let child = try container.superDecoder()
        unkeyed = container
        return child
    }
}

extension JSONValue {
    /// Writes the tree through an encoder: objects as keyed containers,
    /// arrays as unkeyed ones, scalars as single values. Integers that fit
    /// are written as `Int64` or `UInt64`, so they are exact; other numbers
    /// as `Double`, which is what an encoder can be given.
    public func write(to encoder: any Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .bool(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .number(let number):
            var container = encoder.singleValueContainer()
            if number.isInteger, let value = number.int64 {
                try container.encode(value)
            } else if number.isInteger, let value = number.uint64 {
                try container.encode(value)
            } else if let value = number.double {
                try container.encode(value)
            } else {
                throw EncodingError.invalidValue(
                    number,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "\(number.lexeme) is not a number a Double can hold"))
            }
        case .array(let items):
            var container = encoder.unkeyedContainer()
            for item in items { try container.encode(JSONNode(item)) }
        case .object(let object):
            var container = encoder.container(keyedBy: DynamicKey.self)
            for member in object {
                try container.encode(JSONNode(member.value), forKey: DynamicKey(stringValue: member.key))
            }
        }
    }
}
