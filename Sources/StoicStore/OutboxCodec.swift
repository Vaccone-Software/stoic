internal import Foundation

/// How an ``Outbox`` turns its items into bytes and back.
///
/// A pair of closures rather than a `Codable` requirement, because encoding
/// is the app's decision: JSON for readability, a property list for size, a
/// schema-validated document (StoicSchema) for strictness. The core of this
/// package is Foundation-free, so it does not choose for you; ``json(_:)``
/// is the one-line choice for the common case.
public struct OutboxCodec<Item: Sendable>: Sendable {
    public let encode: @Sendable (Item) throws -> [UInt8]
    public let decode: @Sendable ([UInt8]) throws -> Item

    public init(
        encode: @escaping @Sendable (Item) throws -> [UInt8],
        decode: @escaping @Sendable ([UInt8]) throws -> Item
    ) {
        self.encode = encode
        self.decode = decode
    }
}

extension OutboxCodec where Item == [UInt8] {
    /// Items that are already bytes.
    public static var bytes: OutboxCodec { OutboxCodec(encode: { $0 }, decode: { $0 }) }
}

extension OutboxCodec where Item == String {
    /// Items that are text, stored as UTF-8.
    public static var utf8: OutboxCodec {
        OutboxCodec(encode: { Array($0.utf8) }, decode: { String(decoding: $0, as: UTF8.self) })
    }
}

extension OutboxCodec where Item: Codable {
    /// Items stored as JSON, using Foundation's coders with their defaults.
    ///
    /// Changing `Item` later is a migration: entries written by an older
    /// version must still decode, or they are reported at delivery and stay
    /// pending until the app handles them (``Outbox/discard(_:)``).
    public static func json(_ type: Item.Type = Item.self) -> OutboxCodec {
        OutboxCodec(
            encode: { Array(try JSONEncoder().encode($0)) },
            decode: { try JSONDecoder().decode(Item.self, from: Data($0)) }
        )
    }
}
