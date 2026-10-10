internal import Synchronization

/// A key that lets a server recognise a retried request as the same request.
///
/// Retrying a request that changes something — a payment, a message, an
/// upload — risks doing it twice when the first attempt succeeded but its
/// response was lost. The fix is an idempotency key: one key for the
/// *operation*, sent with every attempt, so the server can return the first
/// result instead of acting again (Stripe's `Idempotency-Key` header is the
/// best-known example).
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
    /// from the ambient random source. Keys are always distinct; under a
    /// seed they are also reproducible when a test draws them in the same
    /// order.
    public static func random(fileID: String = #fileID, line: UInt = #line) -> IdempotencyKey {
        var generator = Ambient.current.random.generator(discriminator: IdempotencyKeyCounter.next(), fileID: fileID, line: line)
        let high = generator.next()
        let low = generator.next()
        return IdempotencyKey(rawValue: hex(high) + hex(low))
    }

    public var description: String { rawValue }

    private static func hex(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }
}


/// Separates keys drawn at one call site under a seed: without it, a seeded
/// test would draw the same "random" key every time it reached that line.
enum IdempotencyKeyCounter {
    private static let counter = Atomic<UInt64>(0)

    static func next() -> UInt64 {
        counter.wrappingAdd(1, ordering: .relaxed).newValue
    }
}
