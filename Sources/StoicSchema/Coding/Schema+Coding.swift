internal import StoicJSON

extension CodingUserInfoKey {
    /// A ``DecodeOptions`` value in a decoder's `userInfo`, to decode
    /// schema-backed values through `Codable` leniently (or otherwise
    /// differently from `.strict`) without changing any `init(from:)`.
    public static let schemaDecodeOptions = userInfoKey("stoic.schema.decodeOptions")

    /// An ``EncodeStyle`` value in an encoder's `userInfo`, for sparse
    /// output through `Codable`.
    public static let schemaEncodeStyle = userInfoKey("stoic.schema.encodeStyle")

    /// `CodingUserInfoKey` has a failable initialiser only because the raw
    /// value may not be empty; these are literals that are not.
    private static func userInfoKey(_ name: String) -> CodingUserInfoKey {
        guard let key = CodingUserInfoKey(rawValue: name) else { preconditionFailure("an empty user info key") }
        return key
    }
}

extension Schema {
    /// Decodes the value at a decoder's position through the schema.
    ///
    /// This lets a schema-backed type sit inside `Codable` code. The decoder
    /// is walked into a JSON tree (see ``JSONValue/init(reading:limits:)``,
    /// under the limits of the options' `parse`), the schema runs on it, and
    /// the outcome is either the value or **one**
    /// `DecodingError.dataCorrupted` whose description lists every issue the
    /// schema found, each with its full path from the root of the document
    /// (the decoder's coding path, then the schema's path below it) and
    /// whose underlying error is the ``ValidationFailure``, for code that
    /// wants the issues as data. Accumulation survives inside the schema's
    /// subtree; the surrounding `Codable` code still stops at the first
    /// error, as it always does.
    ///
    ///     struct Document: Decodable {
    ///         var title: String
    ///         var settings: Settings
    ///
    ///         init(from decoder: any Decoder) throws {
    ///             let container = try decoder.container(keyedBy: CodingKeys.self)
    ///             title = try container.decode(String.self, forKey: .title)
    ///             settings = try container.decodeSchema(Settings.self, forKey: .settings)
    ///         }
    ///     }
    ///
    /// - Parameter options: How to decode. Defaults to the
    ///   ``CodingUserInfoKey/schemaDecodeOptions`` in the decoder's user
    ///   info, and then to `.strict`. Warnings and repairs are dropped on
    ///   the success path, as in ``decode(_:options:)-(String,_)``.
    public func decode(from decoder: any Decoder, options: DecodeOptions? = nil) throws -> Value {
        let chosen = options ?? (decoder.userInfo[.schemaDecodeOptions] as? DecodeOptions) ?? .strict
        let json = try JSONValue(reading: decoder, limits: chosen.parse)
        let result = decode(json, options: chosen)
        if let value = result.value { return value }
        let prefix = JSONPath(decoder.codingPath.map { key in
            key.intValue.map { JSONPath.Component.index($0) } ?? .key(key.stringValue)
        })
        let issues = result.issues.map { issue -> Issue in
            var shown = issue
            shown.path = JSONPath(prefix.components + issue.path.components)
            return shown
        }
        let count = issues.filter { $0.severity == .error }.count
        let place = prefix.components.isEmpty ? "the document" : "\(prefix)"
        let description =
            "\(count) problem\(count == 1 ? "" : "s") in \(place):\n"
            + issues.map { "  " + $0.description }.joined(separator: "\n")
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath, debugDescription: description,
                underlyingError: ValidationFailure(issues: issues)))
    }

    /// Writes the value through an encoder, as the JSON the schema encodes
    /// it to.
    ///
    /// - Parameter style: How to encode. Defaults to the
    ///   ``CodingUserInfoKey/schemaEncodeStyle`` in the encoder's user
    ///   info, and then to `.full`, the faithful copy a `Codable` store
    ///   expects.
    public func encode(_ value: Value, to encoder: any Encoder, style: EncodeStyle? = nil) throws {
        let chosen = style ?? (encoder.userInfo[.schemaEncodeStyle] as? EncodeStyle) ?? .full
        var state = EncodeState(style: chosen)
        let json = self.encoder(value, &state) ?? .null
        if let problem = state.problems.first {
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(
                    codingPath: encoder.codingPath, debugDescription: problem.description,
                    underlyingError: ValidationFailure(issues: state.problems)))
        }
        try json.write(to: encoder)
    }
}

/// A schema-backed value that is also `Codable`: wraps it so it can be a
/// property, an array element or a dictionary value in code that uses
/// `Codable`, and be validated by its schema on the way in.
///
///     struct Envelope: Codable {
///         var id: Int
///         var settings: SchemaCoded<Settings>
///     }
///
/// Decoding throws one `DecodingError.dataCorrupted` listing every issue
/// with its full path (see ``Schema/decode(from:options:)``); encoding writes
/// what the schema encodes.
public struct SchemaCoded<Value: Schematic>: Codable, Sendable {
    public var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    public init(from decoder: any Decoder) throws {
        value = try Value.schema.decode(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        try Value.schema.encode(value, to: encoder)
    }
}

extension SchemaCoded: Equatable where Value: Equatable {}
extension SchemaCoded: Hashable where Value: Hashable {}

extension KeyedDecodingContainer {
    /// Decodes a schema-backed value stored under `key`.
    public func decodeSchema<Value: Schematic>(_ type: Value.Type, forKey key: Key) throws -> Value {
        try decode(SchemaCoded<Value>.self, forKey: key).value
    }

    /// Decodes it if the key is present and not null.
    public func decodeSchemaIfPresent<Value: Schematic>(_ type: Value.Type, forKey key: Key) throws -> Value? {
        try decodeIfPresent(SchemaCoded<Value>.self, forKey: key)?.value
    }
}

extension UnkeyedDecodingContainer {
    /// Decodes the next element as a schema-backed value.
    public mutating func decodeSchema<Value: Schematic>(_ type: Value.Type) throws -> Value {
        try decode(SchemaCoded<Value>.self).value
    }
}

extension KeyedEncodingContainer {
    /// Encodes a schema-backed value under `key`.
    public mutating func encodeSchema<Value: Schematic>(_ value: Value, forKey key: Key) throws {
        try encode(SchemaCoded(value), forKey: key)
    }
}
