#if STOIC_CRYPTO
internal import Crypto

/// The label a sealed value carries to say which key sealed it: 16 random
/// bytes, chosen when the key is made. Not secret, and says nothing about the
/// key; it is what lets a keyring that holds several keys, and a log written
/// across a rotation, find the right one.
public struct KeyID: Sendable, Hashable, CustomStringConvertible {
    public static let byteCount = 16

    public let bytes: [UInt8]

    /// `nil` unless `bytes` is exactly ``byteCount`` bytes.
    public init?(bytes: [UInt8]) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = bytes
    }

    private init(exactly bytes: [UInt8]) { self.bytes = bytes }

    /// A fresh identifier, from the same system source as the keys
    /// (swift-crypto's `SymmetricKey`), never from Stoic's ambient randomness.
    static func random() -> KeyID {
        let source = SymmetricKey(size: .bits128)
        return KeyID(exactly: unsafe source.withUnsafeBytes { unsafe Array($0) })
    }

    /// Lowercase hexadecimal.
    public var description: String {
        let digits = Array("0123456789abcdef")
        var text = ""
        for byte in bytes {
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0F)])
        }
        return text
    }
}

/// A 256-bit AES-GCM key and the ``KeyID`` that names it.
///
/// Made with ``generate()`` (from the system's secure random source, through
/// swift-crypto) or imported from the 48 bytes ``exportedForWrapping()``
/// produced. Not `Codable`, not `Equatable`, and nothing that prints it, logs
/// it or reflects over it shows more than its identifier.
///
/// **Memory.** The key lives in swift-crypto's `SymmetricKey`, which keeps it
/// in memory it clears when released; the bytes ``exportedForWrapping()``
/// returns, and every plaintext and sealed value in an `Array`, are ordinary
/// Swift memory. Swift cannot promise that a copy is erased, moved or kept out
/// of a swap file or a crash dump, and neither does this library. What keeps
/// a key from a stolen disk is that it is never written beside the data it
/// seals (design/24).
public struct SealingKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The size of ``exportedForWrapping()``: the identifier, then the key.
    public static let exportedByteCount = KeyID.byteCount + 32

    public let id: KeyID
    let material: SymmetricKey

    private init(id: KeyID, material: SymmetricKey) {
        self.id = id
        self.material = material
    }

    /// A new random key under a new random identifier.
    public static func generate() -> SealingKey {
        SealingKey(id: .random(), material: SymmetricKey(size: .bits256))
    }

    /// A key from the bytes ``exportedForWrapping()`` returned: the 16-byte
    /// identifier followed by the 32-byte key. `nil` for any other length.
    public init?(importing exported: [UInt8]) {
        guard exported.count == Self.exportedByteCount, let id = KeyID(bytes: Array(exported[..<KeyID.byteCount])) else { return nil }
        self.init(id: id, material: SymmetricKey(data: exported[KeyID.byteCount...]))
    }

    /// The key's bytes, for a caller that keeps a key inside something it
    /// seals: a per-object key stored in a sealed record, so that dropping the
    /// record shreds the object. Named so that it is not called by accident.
    ///
    /// The result is the identifier then the key, ``exportedByteCount`` bytes,
    /// and is the key itself: store it only sealed under another key, and
    /// never log it. See the type's note on memory.
    public func exportedForWrapping() -> [UInt8] {
        let key = unsafe material.withUnsafeBytes { unsafe Array($0) }
        return id.bytes + key
    }

    public var description: String { "SealingKey(id: \(id))" }
    public var debugDescription: String { description }

    /// Reflection (`dump`, a debugger's summary, a logging library that
    /// mirrors a value) shows the identifier and nothing else.
    public var customMirror: Mirror {
        Mirror(self, children: ["id": id.description], displayStyle: .struct)
    }
}
#endif
