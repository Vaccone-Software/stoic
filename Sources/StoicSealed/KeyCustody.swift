#if STOIC_CRYPTO
public import Stoic

/// Somewhere a ``Keyring`` is kept that is not beside the data it protects: the
/// Keychain, a secrets service, a file the user's login protects.
///
/// A custody holds named byte strings (a keyring's serialised form; it knows
/// nothing of keys). It is the one place a key can be lost, so its contract is
/// strict, and a conforming type owes:
///
/// - **`nil` means definitely absent.** ``load(name:)`` returns `nil` only when
///   the item is known not to exist. A custody that cannot look (locked,
///   denied, cancelled, interaction not allowed, unreachable) *throws*, with
///   ``CustodyError/unavailable(_:)`` where the item may well exist. A caller
///   that sees `nil` may create a new keyring, which orphans everything sealed
///   under the old one; a custody that answers `nil` for "could not read" makes
///   that destruction its own doing.
/// - **`store` is atomic.** After a failure, or a crash, the item holds the old
///   bytes or the new ones, in full. A keychain update is. A file is only if
///   it is written with `AtomicFile` (or the equivalent). Every state a
///   ``Keyring`` can leave the item in is then readable, because each is a
///   whole ring.
/// - **Replacing is `store`'s job.** `store` on an existing name replaces it.
///   `delete` of an absent name succeeds.
/// - **Safe from many threads**, synchronous, and allowed to block (the Keychain
///   can wait on a user prompt): call it off the main actor.
/// - **Errors carry no name and no bytes.**
///
/// ``InMemoryKeyCustody`` is the test double. For the Keychain, an app writes
/// ten lines over `SecretStore` (design/24); `StoicSealed` does not know the
/// Keychain, so it never has to be linked to it.
public protocol KeyCustody: Sendable {
    /// The bytes kept under `name`, or `nil` if there is definitely nothing.
    func load(name: String) throws(CustodyError) -> [UInt8]?
    /// Keeps `bytes` under `name`, replacing what was there, atomically.
    func store(_ bytes: [UInt8], name: String) throws(CustodyError)
    /// Forgets `name`. Not an error if there was nothing under it.
    func delete(name: String) throws(CustodyError)
}

/// Why a ``KeyCustody`` call failed.
///
/// The first case is the one that matters: ``unavailable(_:)`` says **the
/// item may exist and could not be reached**, and a caller must never answer it
/// by creating a replacement or wiping data. It is a reason to wait, to ask the
/// user, or to refuse and say why.
///
/// Neither the cases nor their descriptions carry the item's name, its bytes or
/// the system's message, which can quote them.
public enum CustodyError: Error, Sendable, Hashable, CustomStringConvertible, Retryable {
    /// Why the custody could not be reached.
    public enum Reason: Sendable, Hashable {
        /// The device or keychain is locked.
        case locked
        /// The system or the user refused access (a denied prompt, a wrong
        /// password, an entitlement the app lacks).
        case accessDenied
        /// The user cancelled the prompt.
        case userCancelled
        /// There is no way to ask: no user session, a background process, a
        /// non-interactive context.
        case interactionNotAllowed
        /// The service or the store itself did not answer.
        case serviceUnavailable
    }

    /// The custody could not be reached: **the item may exist.**
    case unavailable(Reason)
    /// The name is empty.
    case invalidName
    /// Any other failure, by the code the custody gave (an `OSStatus`, an
    /// errno): the item's state is unknown, and is not "absent".
    case other(code: Int)

    public var description: String {
        switch self {
        case .unavailable(.locked): "custody unavailable: locked"
        case .unavailable(.accessDenied): "custody unavailable: access denied"
        case .unavailable(.userCancelled): "custody unavailable: the user cancelled"
        case .unavailable(.interactionNotAllowed): "custody unavailable: interaction not allowed"
        case .unavailable(.serviceUnavailable): "custody unavailable: the service did not answer"
        case .invalidName: "invalid name"
        case .other(let code): "custody failed (code \(code))"
        }
    }

    /// A locked custody unlocks and a busy service recovers; a refusal or a
    /// cancellation would be repeated by asking again.
    public var retryDecision: RetryDecision {
        switch self {
        case .unavailable(.locked), .unavailable(.interactionNotAllowed), .unavailable(.serviceUnavailable): .retry
        case .unavailable(.accessDenied), .unavailable(.userCancelled), .invalidName, .other: .stop
        }
    }

    /// Whether the item may exist and could not be reached: the case that must
    /// never be treated as "missing".
    public var itemMayExist: Bool {
        switch self {
        case .unavailable, .other: true
        case .invalidName: false
        }
    }
}
#endif
