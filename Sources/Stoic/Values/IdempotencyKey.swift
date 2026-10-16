/// A key that lets a server recognise a retried request as the same request.
///
/// Retrying a request that changes something — a payment, a message, an
/// upload — risks doing it twice when the first attempt succeeded but its
/// response was lost. The fix is an idempotency key: one key for the
/// *operation*, sent with every attempt, so the server can return the first
/// result instead of acting again (Stripe's `Idempotency-Key` header is the
/// best-known example).
///
/// A key is `Codable` as the bare string, so one dropped into JSON reads
/// `"7f3a…"`, not an object; decoding refuses an empty string, which no
/// server would take as a key and a missing value would otherwise hide.
///
/// The one rule that matters: every attempt carries the same key. Inside a
/// `retry`, ``Attempt/idempotencyKey`` is that key; drawn by hand, the key
/// must be created *outside* the retry (`stoic.key-inside-retry` flags one
/// drawn inside).
///
///     try await retry(.exponential(base: .seconds(1)).attempts(5)) { attempt in
///         try await payments.charge(order, idempotencyKey: attempt.idempotencyKey)
///     }
///
///     let key = IdempotencyKey.random()   // the same, by hand: before the retry
///     try await retry(.exponential(base: .seconds(1)).attempts(5)) { _ in
///         try await payments.charge(order, idempotencyKey: key)
///     }
public struct IdempotencyKey: Sendable, Hashable, CustomStringConvertible, Codable {
    /// The key as sent to the server.
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// A new 128-bit random key, as 32 lowercase hexadecimal digits, drawn
    /// from the ambient random source. Keys drawn from one source are always
    /// distinct. Under a seed they are also reproducible: the keys a test
    /// draws depend on the seed, the call site and how many keys that test's
    /// own source has drawn so far — never on other tests, the filter used
    /// to run it, or what ran in parallel.
    public static func random(fileID: String = #fileID, line: UInt = #line) -> IdempotencyKey {
        let source = Ambient.current.random
        var generator = source.generator(discriminator: source.nextDraw(), fileID: fileID, line: line)
        let high = generator.next()
        let low = generator.next()
        return IdempotencyKey(rawValue: hex(high) + hex(low))
    }

    /// The key of a sub-operation: a function of the enclosing operation's
    /// key, the sub-operation's call site and its ordinal there, so it is the
    /// same on every attempt of the enclosing operation (see
    /// `OperationIdentity`). It inherits its unpredictability from the
    /// parent's random key: each half is a stable hash of one half of the
    /// parent and the site, so the parent's 128 bits all count.
    static func derived(from parent: IdempotencyKey, fileID: String, line: UInt, ordinal: Int) -> IdempotencyKey {
        func half(_ part: Substring, _ which: UInt64) -> UInt64 {
            var hash = StableHash()
            hash.combine(which)
            hash.combine(part.utf8)
            hash.combine(fileID)
            hash.combine(UInt64(line))
            hash.combine(UInt64(truncatingIfNeeded: ordinal))
            // A SplitMix64 finalizer: FNV's low bits mix poorly on their own.
            var z = hash.value &+ 0x9E37_79B9_7F4A_7C15
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        let raw = parent.rawValue
        let middle = raw.index(raw.startIndex, offsetBy: raw.count / 2)
        return IdempotencyKey(rawValue: hex(half(raw[..<middle], 0)) + hex(half(raw[middle...], 1)))
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard !value.isEmpty else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "An idempotency key cannot be empty")
        }
        rawValue = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func hex(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }
}

