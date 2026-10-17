#if STOIC_CRYPTO
public import Stoic

/// Why a sealed value could not be opened (or sealed).
///
/// Four of the cases are four different facts, and a caller that treats them
/// alike will do the wrong thing to somebody's data:
///
/// - ``tampered``: the authentication tag did not verify. The bytes were
///   changed, the value was moved to another context, or it was sealed under a
///   different key than the one the header names. The cipher cannot tell these
///   apart, and neither can this error. The data is not usable and says
///   nothing about *why*.
/// - ``torn``: the value begins like a sealed one and ends before it should. A
///   frame cut short, as a crash leaves the end of a log. Nothing was altered.
/// - ``unknownKey``: the value names a key the keyring does not hold. The key
///   was retired, or lost with its custody item: the data is intact, and only
///   the key is missing. Often the right response is to say so and ask for the
///   key back, never to delete the data.
/// - ``notSealed``: no sealed-value header at all. Plaintext, or some other
///   format. Nothing was tried; it may be perfectly good data waiting to be
///   adopted (``SealedFile/adopt(path:context:)``).
///
/// The cases and their descriptions carry no key, no key byte, no nonce and
/// no plaintext, and ``unknownKey`` carries only the key's identifier (a
/// random label, not secret) so that an app can look the key up on purpose;
/// the description leaves even that out.
public enum SealError: Error, Sendable, Hashable, CustomStringConvertible, Retryable {
    /// Authentication failed: altered, moved to another context, or under
    /// another key. Not distinguishable.
    case tampered
    /// A sealed value that stops short of its own end.
    case torn
    /// The value names a key identifier the keyring does not hold.
    case unknownKey(KeyID)
    /// Not a sealed value: no header.
    case notSealed
    /// A sealed value in a format this version cannot read: another format
    /// version or algorithm, written by a newer release (or by an edit to
    /// those bytes, which cannot be told from it).
    case unsupportedFormat(version: UInt8, algorithm: UInt8)
    /// The cipher refused to seal. Not a condition an input of ordinary size
    /// can produce: the plaintext is larger than AES-GCM can seal.
    case encryptionFailed

    public var description: String {
        switch self {
        case .tampered: "authentication failed: the data was altered, moved to another context, or sealed under another key"
        case .torn: "incomplete: a sealed value cut short"
        case .unknownKey: "sealed under a key the keyring does not hold"
        case .notSealed: "not sealed: no sealed-value header"
        case .unsupportedFormat(let version, let algorithm): "unsupported sealed format (version \(version), algorithm \(algorithm))"
        case .encryptionFailed: "the cipher refused to seal this value"
        }
    }

    /// Nothing about trying again changes any of these.
    public var retryDecision: RetryDecision { .stop }

    /// A short, stable name for the kind, for events and metrics: carries
    /// nothing about the value.
    var label: String {
        switch self {
        case .tampered: "tampered"
        case .torn: "torn"
        case .unknownKey: "unknown_key"
        case .notSealed: "not_sealed"
        case .unsupportedFormat: "unsupported_format"
        case .encryptionFailed: "encryption_failed"
        }
    }
}
#endif
