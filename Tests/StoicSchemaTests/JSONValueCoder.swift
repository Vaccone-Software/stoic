import StoicJSON

// A minimal Decoder and Encoder over JSONValue, with no Foundation, to test the
// Codable bridge against something that is not JSONDecoder. Deliberately strict:
// a Bool is a boolean, a number is a number, an integer type takes only
// integers that fit.

struct ValueDecoder: Decoder {
    var value: JSONValue
    var codingPath: [any CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .object(let object) = value else {
            throw DecodingError.typeMismatch(
                [String: Any].self, .init(codingPath: codingPath, debugDescription: "not an object: \(value.kindName)"))
        }
        return KeyedDecodingContainer(ObjectDecodingContainer<Key>(object: object, decoder: self))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard case .array(let items) = value else {
            throw DecodingError.typeMismatch(
                [Any].self, .init(codingPath: codingPath, debugDescription: "not an array: \(value.kindName)"))
        }
        return ArrayDecodingContainer(items: items, decoder: self)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        ScalarDecodingContainer(decoder: self)
    }

    func child(_ value: JSONValue, _ key: any CodingKey) -> ValueDecoder {
        ValueDecoder(value: value, codingPath: codingPath + [key], userInfo: userInfo)
    }
}

private struct ScalarDecodingContainer: SingleValueDecodingContainer {
    let decoder: ValueDecoder
    var codingPath: [any CodingKey] { decoder.codingPath }

    func decodeNil() -> Bool { decoder.value.isNull }

    private func mismatch<T>(_ type: T.Type) -> DecodingError {
        .typeMismatch(type, .init(codingPath: codingPath, debugDescription: "found \(decoder.value.kindName)"))
    }

    private func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        guard case .number(let number) = decoder.value, number.isInteger else { throw mismatch(type) }
        if let value = number.int64.flatMap({ T(exactly: $0) }) ?? number.uint64.flatMap({ T(exactly: $0) }) { return value }
        throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "\(number) does not fit \(type)"))
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        guard let value = decoder.value.bool else { throw mismatch(type) }
        return value
    }

    func decode(_ type: String.Type) throws -> String {
        guard let value = decoder.value.string else { throw mismatch(type) }
        return value
    }

    func decode(_ type: Double.Type) throws -> Double {
        guard let value = decoder.value.number?.double else { throw mismatch(type) }
        return value
    }

    func decode(_ type: Float.Type) throws -> Float {
        guard let value = decoder.value.number?.double else { throw mismatch(type) }
        return Float(value)
    }

    func decode(_ type: Int.Type) throws -> Int { try integer(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { try integer(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { try integer(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { try integer(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { try integer(type) }
    func decode(_ type: UInt.Type) throws -> UInt { try integer(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try integer(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try integer(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try integer(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try integer(type) }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try T(from: decoder)
    }
}

private struct ObjectDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let object: JSONObject
    let decoder: ValueDecoder
    var codingPath: [any CodingKey] { decoder.codingPath }

    var allKeys: [Key] { object.keys.compactMap { Key(stringValue: $0) } }

    func contains(_ key: Key) -> Bool { object.contains(key: key.stringValue) }

    private func sub(_ key: Key) throws -> ValueDecoder {
        guard let value = object[key.stringValue] else {
            throw DecodingError.keyNotFound(
                key, .init(codingPath: codingPath, debugDescription: "no value for \(key.stringValue)"))
        }
        return decoder.child(value, key)
    }

    func decodeNil(forKey key: Key) throws -> Bool { try sub(key).value.isNull }
    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try Bool(from: sub(key)) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try String(from: sub(key)) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try Double(from: sub(key)) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try Float(from: sub(key)) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try Int(from: sub(key)) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try Int8(from: sub(key)) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try Int16(from: sub(key)) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try Int32(from: sub(key)) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try Int64(from: sub(key)) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try UInt(from: sub(key)) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try UInt8(from: sub(key)) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try UInt16(from: sub(key)) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try UInt32(from: sub(key)) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try UInt64(from: sub(key)) }
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T { try T(from: sub(key)) }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws
        -> KeyedDecodingContainer<NestedKey>
    {
        try sub(key).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        try sub(key).unkeyedContainer()
    }

    func superDecoder() throws -> any Decoder { decoder }
    func superDecoder(forKey key: Key) throws -> any Decoder { try sub(key) }
}

private struct ArrayDecodingContainer: UnkeyedDecodingContainer {
    let items: [JSONValue]
    let decoder: ValueDecoder
    var currentIndex = 0
    var codingPath: [any CodingKey] { decoder.codingPath }
    var count: Int? { items.count }
    var isAtEnd: Bool { currentIndex >= items.count }

    init(items: [JSONValue], decoder: ValueDecoder) {
        self.items = items
        self.decoder = decoder
    }

    private mutating func next() throws -> ValueDecoder {
        guard currentIndex < items.count else {
            throw DecodingError.valueNotFound(
                JSONValue.self, .init(codingPath: codingPath, debugDescription: "no more elements"))
        }
        defer { currentIndex += 1 }
        return decoder.child(items[currentIndex], ArrayIndexKey(currentIndex))
    }

    mutating func decodeNil() throws -> Bool {
        guard currentIndex < items.count else { return false }
        if items[currentIndex].isNull {
            currentIndex += 1
            return true
        }
        return false
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool { try Bool(from: next()) }
    mutating func decode(_ type: String.Type) throws -> String { try String(from: next()) }
    mutating func decode(_ type: Double.Type) throws -> Double { try Double(from: next()) }
    mutating func decode(_ type: Float.Type) throws -> Float { try Float(from: next()) }
    mutating func decode(_ type: Int.Type) throws -> Int { try Int(from: next()) }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { try Int8(from: next()) }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try Int16(from: next()) }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try Int32(from: next()) }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try Int64(from: next()) }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try UInt(from: next()) }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try UInt8(from: next()) }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try UInt16(from: next()) }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try UInt32(from: next()) }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try UInt64(from: next()) }
    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T { try T(from: next()) }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws
        -> KeyedDecodingContainer<NestedKey>
    {
        try next().container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        try next().unkeyedContainer()
    }

    mutating func superDecoder() throws -> any Decoder { try next() }
}

struct ArrayIndexKey: CodingKey {
    var stringValue: String { "Index \(index)" }
    var intValue: Int? { index }
    let index: Int

    init(_ index: Int) { self.index = index }
    init?(stringValue: String) { nil }
    init?(intValue: Int) { index = intValue }
}

// MARK: - Encoder

final class EncodingBox {
    enum Content {
        case empty
        case scalar(JSONValue)
        case object([(String, EncodingBox)])
        case array([EncodingBox])
    }

    var content = Content.empty

    func finish() -> JSONValue {
        switch content {
        case .empty: return .null
        case .scalar(let value): return value
        case .object(let members):
            return .object(JSONObject(members.map { JSONObject.Member(key: $0.0, value: $0.1.finish()) }))
        case .array(let boxes): return .array(boxes.map { $0.finish() })
        }
    }
}

struct ValueEncoder: Encoder {
    let box: EncodingBox
    var codingPath: [any CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]

    init(box: EncodingBox = EncodingBox(), codingPath: [any CodingKey] = [], userInfo: [CodingUserInfoKey: Any] = [:]) {
        self.box = box
        self.codingPath = codingPath
        self.userInfo = userInfo
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        box.content = .object([])
        return KeyedEncodingContainer(ObjectEncodingContainer<Key>(encoder: self))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        box.content = .array([])
        return ArrayEncodingContainer(encoder: self)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
        ScalarEncodingContainer(encoder: self)
    }

    func child(_ box: EncodingBox, _ key: any CodingKey) -> ValueEncoder {
        ValueEncoder(box: box, codingPath: codingPath + [key], userInfo: userInfo)
    }
}

/// Encodes a value into a JSON tree.
func encodeToValue<T: Encodable>(_ value: T, userInfo: [CodingUserInfoKey: Any] = [:]) throws -> JSONValue {
    let box = EncodingBox()
    try value.encode(to: ValueEncoder(box: box, userInfo: userInfo))
    return box.finish()
}

/// Decodes a value from a JSON tree.
func decodeFromValue<T: Decodable>(_ type: T.Type, _ value: JSONValue, userInfo: [CodingUserInfoKey: Any] = [:]) throws -> T {
    try T(from: ValueDecoder(value: value, userInfo: userInfo))
}

private struct ScalarEncodingContainer: SingleValueEncodingContainer {
    let encoder: ValueEncoder
    var codingPath: [any CodingKey] { encoder.codingPath }

    private func put(_ value: JSONValue) { encoder.box.content = .scalar(value) }
    private func number(_ value: Double) throws {
        guard let number = JSONNumber(value) else {
            throw EncodingError.invalidValue(value, .init(codingPath: codingPath, debugDescription: "not finite"))
        }
        put(.number(number))
    }

    mutating func encodeNil() throws { put(.null) }
    mutating func encode(_ value: Bool) throws { put(.bool(value)) }
    mutating func encode(_ value: String) throws { put(.string(value)) }
    mutating func encode(_ value: Double) throws { try number(value) }
    mutating func encode(_ value: Float) throws { try number(Double(value)) }
    mutating func encode(_ value: Int) throws { put(.number(JSONNumber(value))) }
    mutating func encode(_ value: Int8) throws { put(.number(JSONNumber(value))) }
    mutating func encode(_ value: Int16) throws { put(.number(JSONNumber(value))) }
    mutating func encode(_ value: Int32) throws { put(.number(JSONNumber(value))) }
    mutating func encode(_ value: Int64) throws { put(.number(JSONNumber(value))) }
    mutating func encode(_ value: UInt) throws { put(.number(JSONNumber(value))) }
    mutating func encode(_ value: UInt8) throws { put(.number(JSONNumber(value))) }
    mutating func encode(_ value: UInt16) throws { put(.number(JSONNumber(value))) }
    mutating func encode(_ value: UInt32) throws { put(.number(JSONNumber(value))) }
    mutating func encode(_ value: UInt64) throws { put(.number(JSONNumber(value))) }
    mutating func encode<T: Encodable>(_ value: T) throws { try value.encode(to: encoder) }
}

private struct ObjectEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let encoder: ValueEncoder
    var codingPath: [any CodingKey] { encoder.codingPath }

    private func add(_ key: Key, _ box: EncodingBox) {
        guard case .object(var members) = encoder.box.content else { return }
        members.removeAll { $0.0 == key.stringValue }
        members.append((key.stringValue, box))
        encoder.box.content = .object(members)
    }

    private func scalar(_ key: Key, _ value: JSONValue) {
        let box = EncodingBox()
        box.content = .scalar(value)
        add(key, box)
    }

    mutating func encodeNil(forKey key: Key) throws { scalar(key, .null) }
    mutating func encode(_ value: Bool, forKey key: Key) throws { scalar(key, .bool(value)) }
    mutating func encode(_ value: String, forKey key: Key) throws { scalar(key, .string(value)) }
    mutating func encode(_ value: Double, forKey key: Key) throws { try encode(value as Double, forKeyGeneric: key) }
    mutating func encode(_ value: Float, forKey key: Key) throws { try encode(Double(value), forKeyGeneric: key) }
    mutating func encode(_ value: Int, forKey key: Key) throws { scalar(key, .number(JSONNumber(value))) }
    mutating func encode(_ value: Int8, forKey key: Key) throws { scalar(key, .number(JSONNumber(value))) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { scalar(key, .number(JSONNumber(value))) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { scalar(key, .number(JSONNumber(value))) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { scalar(key, .number(JSONNumber(value))) }
    mutating func encode(_ value: UInt, forKey key: Key) throws { scalar(key, .number(JSONNumber(value))) }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { scalar(key, .number(JSONNumber(value))) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { scalar(key, .number(JSONNumber(value))) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { scalar(key, .number(JSONNumber(value))) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { scalar(key, .number(JSONNumber(value))) }

    private mutating func encode(_ value: Double, forKeyGeneric key: Key) throws {
        guard let number = JSONNumber(value) else {
            throw EncodingError.invalidValue(value, .init(codingPath: codingPath, debugDescription: "not finite"))
        }
        scalar(key, .number(number))
    }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        let box = EncodingBox()
        try value.encode(to: encoder.child(box, key))
        add(key, box)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key)
        -> KeyedEncodingContainer<NestedKey>
    {
        let box = EncodingBox()
        add(key, box)
        return encoder.child(box, key).container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        let box = EncodingBox()
        add(key, box)
        return encoder.child(box, key).unkeyedContainer()
    }

    mutating func superEncoder() -> any Encoder { encoder }
    mutating func superEncoder(forKey key: Key) -> any Encoder {
        let box = EncodingBox()
        add(key, box)
        return encoder.child(box, key)
    }
}

private struct ArrayEncodingContainer: UnkeyedEncodingContainer {
    let encoder: ValueEncoder
    var codingPath: [any CodingKey] { encoder.codingPath }
    var count: Int {
        if case .array(let boxes) = encoder.box.content { return boxes.count }
        return 0
    }

    private func append(_ box: EncodingBox) {
        guard case .array(var boxes) = encoder.box.content else { return }
        boxes.append(box)
        encoder.box.content = .array(boxes)
    }

    private func scalar(_ value: JSONValue) {
        let box = EncodingBox()
        box.content = .scalar(value)
        append(box)
    }

    mutating func encodeNil() throws { scalar(.null) }
    mutating func encode(_ value: Bool) throws { scalar(.bool(value)) }
    mutating func encode(_ value: String) throws { scalar(.string(value)) }
    mutating func encode(_ value: Double) throws {
        guard let number = JSONNumber(value) else {
            throw EncodingError.invalidValue(value, .init(codingPath: codingPath, debugDescription: "not finite"))
        }
        scalar(.number(number))
    }
    mutating func encode(_ value: Float) throws { try encode(Double(value)) }
    mutating func encode(_ value: Int) throws { scalar(.number(JSONNumber(value))) }
    mutating func encode(_ value: Int8) throws { scalar(.number(JSONNumber(value))) }
    mutating func encode(_ value: Int16) throws { scalar(.number(JSONNumber(value))) }
    mutating func encode(_ value: Int32) throws { scalar(.number(JSONNumber(value))) }
    mutating func encode(_ value: Int64) throws { scalar(.number(JSONNumber(value))) }
    mutating func encode(_ value: UInt) throws { scalar(.number(JSONNumber(value))) }
    mutating func encode(_ value: UInt8) throws { scalar(.number(JSONNumber(value))) }
    mutating func encode(_ value: UInt16) throws { scalar(.number(JSONNumber(value))) }
    mutating func encode(_ value: UInt32) throws { scalar(.number(JSONNumber(value))) }
    mutating func encode(_ value: UInt64) throws { scalar(.number(JSONNumber(value))) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        let box = EncodingBox()
        try value.encode(to: encoder.child(box, ArrayIndexKey(count)))
        append(box)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        let box = EncodingBox()
        let key = ArrayIndexKey(count)
        append(box)
        return encoder.child(box, key).container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        let box = EncodingBox()
        let key = ArrayIndexKey(count)
        append(box)
        return encoder.child(box, key).unkeyedContainer()
    }

    mutating func superEncoder() -> any Encoder {
        let box = EncodingBox()
        let key = ArrayIndexKey(count)
        append(box)
        return encoder.child(box, key)
    }
}
