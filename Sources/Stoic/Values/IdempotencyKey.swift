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
/// The one rule that matters: create the key *outside* the retry, so every
/// attempt carries the same one.
///
///     let key = IdempotencyKey.random()
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

