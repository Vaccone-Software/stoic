#if STOIC_CRYPTO

/// What a sealed value is *for*: a purpose and, usually, the logical id of the
/// object, authenticated with the value and stored nowhere.
///
///     let context = SealContext("lodestar.clipboard.blob", clip.id.uuidString)
///
/// Sealing binds the value to its context, so a value copied under another id,
/// or into another kind of record, fails to open (``SealError/tampered``): an
/// attacker who can write the files cannot swap one sealed value for another.
/// Use **logical** ids, never file paths, which change when a file is renamed
/// or a store is moved.
///
/// Each part is length-prefixed, so `("ab", "c")` and `("a", "bc")` are
/// different contexts, and contexts are compared as exact UTF-8 bytes. A
/// context is authenticated, not encrypted, and appears in no file: keep
/// secrets out of it, and keep it the same for as long as the data lives.
/// Events carry only the first part, the purpose, so make it a constant.
public struct SealContext: Sendable, Hashable, ExpressibleByStringLiteral {
    /// What the context stands for. The domain keeps the contexts a layer
    /// derives (a journal's records, its snapshot) from ever being equal to
    /// one an app wrote: the app's are always `.value`.
    enum Domain: UInt8, Sendable {
        case value = 1
        case journalRecord = 2
        case journalSnapshot = 3
    }

    /// The purpose first, then any ids.
    public let parts: [String]
    let domain: Domain

    public init(_ purpose: String, _ ids: String...) {
        self.init(parts: [purpose] + ids, domain: .value)
    }

    public init(stringLiteral purpose: String) {
        self.init(parts: [purpose], domain: .value)
    }

    private init(parts: [String], domain: Domain) {
        self.parts = parts
        self.domain = domain
    }

    /// This context with one more id: a journal's context and a record's.
    public func appending(_ id: String) -> SealContext {
        SealContext(parts: parts + [id], domain: domain)
    }

    /// The context of a thing a layer made, in its own domain, numbered:
    /// record 7 of a journal, the snapshot through record 7.
    func deriving(_ domain: Domain, number: UInt64) -> SealContext {
        SealContext(parts: parts + [String(number)], domain: domain)
    }

    /// The first part: what the value is for.
    var purpose: String { parts.first ?? "" }

    /// The bytes authenticated with a sealed value: the domain, then each part
    /// as a four-byte little-endian length and its UTF-8.
    var associatedData: [UInt8] {
        var bytes: [UInt8] = [domain.rawValue]
        for part in parts {
            let utf8 = Array(part.utf8)
            let count = UInt32(truncatingIfNeeded: utf8.count)
            bytes.append(contentsOf: [UInt8(truncatingIfNeeded: count), UInt8(truncatingIfNeeded: count >> 8),
                                      UInt8(truncatingIfNeeded: count >> 16), UInt8(truncatingIfNeeded: count >> 24)])
            bytes.append(contentsOf: utf8)
        }
        return bytes
    }
}
#endif
