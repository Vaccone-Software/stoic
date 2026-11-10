#if STOIC_ATTESTATION
internal import Crypto
public import Stoic

/// What a challenge is for. The same names and JSON as StoicApple's
/// (design/29, API): neither library can see the other.
public enum AppAttestChallengePurpose: String, Sendable, Hashable, Codable {
    case enrolment, requests

    var byte: UInt8 {
        switch self {
        case .enrolment: 1
        case .requests: 2
        }
    }
}

/// A challenge, and how long it stays good.
public struct AppAttestChallenge: Sendable, Hashable, Codable {
    public let bytes: [UInt8]
    public let lifetime: Duration

    public init(bytes: [UInt8], lifetime: Duration) {
        self.bytes = bytes
        self.lifetime = lifetime
    }
}

/// A challenge that checked: its id (for single use), and when it was issued
/// and expires, by the issuing server's clock.
public struct CheckedChallenge: Sendable, Hashable {
    public let id: [UInt8]
    public let purpose: AppAttestChallengePurpose
    public let issued: Moment
    public let expires: Moment
}

/// Challenges a server issues and checks without storing them: each is MAC'd
/// and dated by the server's own clock (design/29).
///
/// A challenge is 42 bytes: a version (1), the purpose (1 for enrolment, 2
/// for requests), when it was issued (8 bytes, big-endian milliseconds since
/// the epoch), an id (16 random bytes from the system's generator), and a
/// tag: the first 16 bytes of HMAC-SHA-256, under the first key, of the 26
/// bytes before it. Every key checks, so keys rotate by putting the new one
/// first and dropping the old one a lifetime later.
///
/// The server's clock is the only clock: a challenge's age is measured from
/// its issue time to the checking server's now, and one issued more than
/// `maxSkew` in the future (another instance's clock ahead) is refused.
public struct AppAttestChallenges: Sendable {
    static let size = 42
    static let version: UInt8 = 1

    private let keys: [SymmetricKey]
    public let enrolmentLifetime: Duration
    public let requestLifetime: Duration
    public let maxSkew: Duration

    /// - Parameters:
    ///   - keys: 32-byte secrets; the first issues, all check.
    ///   - enrolmentLifetime: 10 minutes: Apple's retries and the enrolment.
    ///   - requestLifetime: 5 minutes: how long a withheld assertion stays usable.
    ///   - maxSkew: 30 s: how far ahead another instance's clock may be.
    /// - Throws: ``ChallengeRefusal/badKey`` for no key or one not 32 bytes.
    public init(
        keys: [Secret<[UInt8]>], enrolmentLifetime: Duration = .seconds(600), requestLifetime: Duration = .seconds(300),
        maxSkew: Duration = .seconds(30)
    ) throws(ChallengeRefusal) {
        guard !keys.isEmpty, keys.allSatisfy({ $0.reveal().count == 32 }) else { throw .badKey }
        precondition(enrolmentLifetime > .zero && requestLifetime > .zero && maxSkew >= .zero, "AppAttestChallenges: positive lifetimes")
        self.keys = keys.map { SymmetricKey(data: $0.reveal()) }
        self.enrolmentLifetime = enrolmentLifetime
        self.requestLifetime = requestLifetime
        self.maxSkew = maxSkew
    }

    /// The lifetime of a challenge for `purpose`.
    public func lifetime(_ purpose: AppAttestChallengePurpose) -> Duration {
        purpose == .enrolment ? enrolmentLifetime : requestLifetime
    }

    /// A new challenge for `purpose`, issued at `now`.
    public func issue(_ purpose: AppAttestChallengePurpose, at now: Moment = .now) -> AppAttestChallenge {
        var generator = SystemRandomNumberGenerator()
        let id = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return AppAttestChallenge(bytes: Self.make(purpose, issued: now, id: id, key: keys[0]), lifetime: lifetime(purpose))
    }

    static func make(_ purpose: AppAttestChallengePurpose, issued: Moment, id: [UInt8], key: SymmetricKey) -> [UInt8] {
        // Clamped to what 8 bytes of milliseconds since 1970 hold: a clock
        // before 1970 or past the year 292 million writes its bound.
        let (seconds, attoseconds) = issued.sinceEpoch.components
        let whole = min(max(seconds, 0), Int64.max / 1000 - 1)
        let milliseconds = UInt64(whole * 1000 + max(0, attoseconds) / 1_000_000_000_000_000)
        var body: [UInt8] = [version, purpose.byte]
        for shift in stride(from: 56, through: 0, by: -8) { body.append(UInt8(truncatingIfNeeded: milliseconds >> UInt64(shift))) }
        body += id
        return body + tag(of: body, key: key)
    }

    static func tag(of body: [UInt8], key: SymmetricKey) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: body, using: key)).prefix(16).map { $0 }
    }

    /// The challenge `bytes` checked for `purpose` at `now`, or why not, in
    /// this order: the shape, the tag, the purpose, the future, the age.
    public func check(_ bytes: [UInt8], for purpose: AppAttestChallengePurpose, at now: Moment = .now) throws(ChallengeRefusal) -> CheckedChallenge {
        guard bytes.count == Self.size, bytes[0] == Self.version else { throw .malformed }
        let body = Array(bytes[0..<26])
        let tag = Array(bytes[26..<42])
        guard keys.contains(where: { Self.constantTimeEqual(Self.tag(of: body, key: $0), tag) }) else { throw .forged }
        guard bytes[1] == purpose.byte else { throw .wrongPurpose }
        var milliseconds: UInt64 = 0
        for byte in bytes[2..<10] { milliseconds = milliseconds << 8 | UInt64(byte) }
        guard milliseconds <= UInt64(Int64.max / 1_000_000) else { throw .malformed }
        let issued = Moment(sinceEpoch: .milliseconds(Int64(milliseconds)))
        let expires = issued + lifetime(purpose)
        guard issued <= now + maxSkew else { throw .fromTheFuture }
        guard now <= expires else { throw .expired }
        return CheckedChallenge(id: Array(bytes[10..<26]), purpose: purpose, issued: issued, expires: expires)
    }

    /// Equality of two tags in time that does not depend on where they
    /// differ: both are MAC'd under a fresh random key and the MACs compared
    /// by swift-crypto's constant-time check, so neither the tag nor its
    /// prefix leaks through timing.
    static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        let key = SymmetricKey(size: .bits256)
        let code = HMAC<SHA256>.authenticationCode(for: lhs, using: key)
        return HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: rhs, using: key)
    }
}

/// Why a challenge does not check.
public enum ChallengeRefusal: Error, Sendable, Hashable, Retryable {
    /// Not 42 bytes of version 1.
    case malformed
    /// No configured key gives its tag: altered, or another server's.
    case forged
    /// An enrolment challenge used for requests, or the reverse.
    case wrongPurpose
    /// Past its lifetime by the server's clock.
    case expired
    /// Issued more than `maxSkew` ahead of the server's clock.
    case fromTheFuture
    /// An enrolment challenge already used.
    case spent
    /// A key that is not 32 bytes, or no key.
    case badKey

    public var retryDecision: RetryDecision { .stop }
}
#endif
