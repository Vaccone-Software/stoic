#if STOIC_ATTESTATION
internal import Crypto
public import Stoic

/// Which assertion counters a key has had accepted: the highest, and a map
/// of the 64 below it (design/29, What the server stores and checks).
///
/// RFC 4303's anti-replay window: a counter `c`
///
/// - above ``highest`` is accepted, and becomes the highest;
/// - within the window below it, not seen before, is accepted;
/// - within the window, seen before, is ``AssertionFailure/replayed(counter:)``;
/// - further below is ``AssertionFailure/counterRegressed(counter:highest:)``.
///
/// So every counter is accepted at most once, in any order within the
/// window, which is what concurrent requests arriving out of order need. A
/// window of 0 is Apple's literal rule: greater than the highest.
public struct AssertionCounter: Sendable, Hashable, Codable {
    /// The highest counter accepted: 0 after enrolment, which is the
    /// attestation's own counter and is never accepted again.
    public let highest: UInt32
    /// Bit `i` set: `highest - i` was accepted.
    public let seen: UInt64

    /// A key just enrolled: counter 0 spent, by the attestation.
    public static let enrolled = AssertionCounter(highest: 0, seen: 1)

    init(highest: UInt32, seen: UInt64) {
        self.highest = highest
        self.seen = seen
    }

    /// The window's largest size: the map has 64 bits, and bit 0 is `highest`.
    public static let maximumReorderWindow = 63

    /// The counter with `counter` accepted, or why not.
    ///
    /// - Parameter reorderWindow: How far below the highest a counter may be
    ///   and still be accepted, 0 to 63.
    public func accepting(_ counter: UInt32, reorderWindow: Int) -> Result<AssertionCounter, AssertionFailure> {
        precondition((0...Self.maximumReorderWindow).contains(reorderWindow), "a reorder window is 0 to 63")
        guard highest < UInt32.max else { return .failure(.counterExhausted) }
        if counter > highest {
            let shift = counter - highest
            let moved = shift >= 64 ? 0 : seen << UInt64(shift)
            return .success(AssertionCounter(highest: counter, seen: moved | 1))
        }
        let distance = highest - counter
        guard distance <= UInt32(reorderWindow) else { return .failure(.counterRegressed(counter: counter, highest: highest)) }
        let bit = UInt64(1) << UInt64(distance)
        guard seen & bit == 0 else { return .failure(.replayed(counter: counter)) }
        return .success(AssertionCounter(highest: highest, seen: seen | bit))
    }
}

/// What the server keeps per key, in its own database (``AppAttestLedger``).
///
/// Made from a verified attestation only (``init(enrolling:account:attestation:at:)``),
/// or decoded from storage, where it is the store's word: a ledger's
/// records are as trustworthy as the database's access control.
public struct AppAttestKeyRecord: Sendable, Hashable, Codable {
    /// Whether the key may still sign.
    public enum Status: Sendable, Hashable, Codable {
        case active
        case revoked(reason: String, at: Moment)
    }

    public let key: AttestedKey
    /// The app's account the key was enrolled for; `nil` when the enrolment
    /// was anonymous, and the key is then accepted for any account.
    public let account: String?
    public let enrolledAt: Moment
    /// SHA-256 of the attestation object: an enrolment sent again is
    /// recognised by it.
    public let attestationDigest: [UInt8]
    public let counter: AssertionCounter
    public let status: Status
    /// 1 at enrolment, one more for every change: what a ledger compares
    /// before it commits.
    public let revision: UInt64

    /// The record of a key Apple certified, enrolled now.
    public init(enrolling key: Verified<AttestedKey, KeyAttested>, account: String?, attestation: [UInt8], at moment: Moment) {
        self.init(
            key: key.value, account: account, enrolledAt: moment, attestationDigest: Self.digest(of: attestation),
            counter: .enrolled, status: .active, revision: 1)
    }

    private init(
        key: AttestedKey, account: String?, enrolledAt: Moment, attestationDigest: [UInt8], counter: AssertionCounter,
        status: Status, revision: UInt64
    ) {
        self.key = key
        self.account = account
        self.enrolledAt = enrolledAt
        self.attestationDigest = attestationDigest
        self.counter = counter
        self.status = status
        self.revision = revision
    }

    /// The record with the key revoked, one revision on: the app's own risk
    /// handling decides when, never a single regression.
    public func revoked(because reason: String, at moment: Moment) -> AppAttestKeyRecord {
        AppAttestKeyRecord(
            key: key, account: account, enrolledAt: enrolledAt, attestationDigest: attestationDigest, counter: counter,
            status: .revoked(reason: reason, at: moment), revision: revision + 1)
    }

    /// The record with `counter` accepted, one revision on.
    func advanced(to counter: AssertionCounter) -> AppAttestKeyRecord {
        AppAttestKeyRecord(
            key: key, account: account, enrolledAt: enrolledAt, attestationDigest: attestationDigest, counter: counter,
            status: status, revision: revision + 1)
    }

    static func digest(of attestation: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: attestation))
    }
}
#endif
