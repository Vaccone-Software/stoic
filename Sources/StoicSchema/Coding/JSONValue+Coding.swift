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

/// A `Codable` carrier for a JSON tree, so that containers can hold one.
private struct JSONNode: Codable {
    var value: JSONValue

    init(_ value: JSONValue) {
        self.value = value
    }

    init(from decoder: any Decoder) throws {
        value = try JSONValue(reading: decoder)
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
    /// `Decoder` promises no order.
    public init(reading decoder: any Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: DynamicKey.self) {
            var object = JSONObject()
            for key in keyed.allKeys.sorted(by: { $0.stringValue.utf8.lexicographicallyPrecedes($1.stringValue.utf8) }) {
                object[key.stringValue] = try keyed.decode(JSONNode.self, forKey: key).value
            }
            self = .object(object)
            return
        }
        if var unkeyed = try? decoder.unkeyedContainer() {
            var items: [JSONValue] = []
            if let count = unkeyed.count { items.reserveCapacity(count) }
            while !unkeyed.isAtEnd { items.append(try unkeyed.decode(JSONNode.self).value) }
            self = .array(items)
            return
        }
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let value = try? single.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? single.decode(String.self) {
            self = .string(value)
        } else if let value = try? single.decode(Int64.self) {
            self = .number(JSONNumber(value))
        } else if let value = try? single.decode(UInt64.self) {
            self = .number(JSONNumber(value))
        } else if let value = try? single.decode(Double.self), let number = JSONNumber(value) {
            self = .number(number)
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "the decoder holds a value that is not null, a boolean, a string, a number, an array or a dictionary"
                ))
        }
    }

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
