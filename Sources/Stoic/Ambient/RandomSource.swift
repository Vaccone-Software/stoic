/// Where Stoic's randomness comes from: the system, or a seed.
///
/// Jitter, hedging and sampling all draw from a `RandomSource`. In production
/// it is the system generator. In a test it is a seed, and a seed must
/// reproduce the same numbers on every run — which a single shared seeded
/// generator cannot do once two tasks draw from it in an order the scheduler
/// picks. So a seeded source hands each call site its own stream, derived
/// from the seed, the site's file and line, and a caller-chosen
/// discriminator (an attempt number, say). The numbers a site sees depend on
/// the seed and the site, never on interleaving.
public struct RandomSource: Sendable, Hashable, CustomStringConvertible {
    private enum Kind: Hashable {
        case system
        case seeded(UInt64)
    }

    private let kind: Kind

    /// The system's cryptographically secure generator.
    public static let system = RandomSource(kind: .system)

    /// A reproducible source: the same seed yields the same streams.
    public static func seeded(_ seed: UInt64) -> RandomSource {
        RandomSource(kind: .seeded(seed))
    }

    /// The seed, when the source is seeded.
    public var seed: UInt64? {
        if case .seeded(let seed) = kind { return seed }
        return nil
    }

    /// A generator for one call site.
    ///
    /// - Parameters:
    ///   - discriminator: Separates streams drawn at the same site, such as
    ///     successive attempts of one retry.
    ///   - fileID: The call site's file, captured by default.
    ///   - line: The call site's line, captured by default.
    public func generator(
        discriminator: UInt64 = 0,
        fileID: String = #fileID,
        line: UInt = #line
    ) -> RandomGenerator {
        switch kind {
        case .system:
            return RandomGenerator(state: .system)
        case .seeded(let seed):
            var hash = StableHash()
            hash.combine(seed)
            hash.combine(fileID)
            hash.combine(UInt64(line))
            hash.combine(discriminator)
            return RandomGenerator(state: .splitMix(hash.value))
        }
    }

    public var description: String {
        switch kind {
        case .system: "system"
        case .seeded(let seed): "seeded(\(seed))"
        }
    }
}

/// A random number generator handed out by a ``RandomSource``.
public struct RandomGenerator: RandomNumberGenerator, Sendable {
    fileprivate enum State: Sendable {
        case system
        case splitMix(UInt64)
    }

    fileprivate var state: State

    public mutating func next() -> UInt64 {
        switch state {
        case .system:
            var system = SystemRandomNumberGenerator()
            return system.next()
        case .splitMix(let current):
            // SplitMix64 (Steele, Lea and Flood, 2014): small, fast, and
            // statistically sound for jitter; not for cryptography.
            let advanced = current &+ 0x9E37_79B9_7F4A_7C15
            state = .splitMix(advanced)
            var z = advanced
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}

/// FNV-1a, 64-bit. `Hasher` is seeded per process, so it cannot derive
/// streams that must be identical across runs; this can.
struct StableHash {
    private(set) var value: UInt64 = 0xCBF2_9CE4_8422_2325

    mutating func combine(_ bytes: some Sequence<UInt8>) {
        for byte in bytes {
            value ^= UInt64(byte)
            value &*= 0x0000_0100_0000_01B3
        }
    }

    mutating func combine(_ string: String) {
        combine(string.utf8)
        combine(CollectionOfOne(0xFF))
    }

    mutating func combine(_ integer: UInt64) {
        var remaining = integer
        var bytes: [UInt8] = []
        bytes.reserveCapacity(8)
        for _ in 0..<8 {
            bytes.append(UInt8(truncatingIfNeeded: remaining))
            remaining >>= 8
        }
        combine(bytes)
    }
}
