public import Foundation
public import Stoic
internal import Synchronization

/// Somewhere to keep small secrets — tokens, keys, passwords — that survive
/// a relaunch and do not sit in a file or in `UserDefaults`.
///
/// The seam over the Keychain: code takes a `SecretStore`, the app passes
/// ``KeychainSecretStore``, tests pass ``InMemorySecretStore``. Values are
/// `Data`; wrap one in `Secret` (Stoic) the moment it leaves the store, so
/// it cannot reach a log.
///
/// The calls are synchronous and may block (the Keychain can wait on the
/// device's first unlock): call them off the main actor.
public protocol SecretStore: Sendable {
    /// The value kept under `key`, or `nil` if there is none.
    ///
    /// `nil` is the only answer that means "definitely absent". A store that
    /// is locked, refuses, was cancelled or cannot be reached throws, and then
    /// the secret may well exist: never create a replacement, or wipe what the
    /// old one protected, on an error.
    func get(_ key: String) throws(SecretStoreError) -> Data?
    /// Keeps `value` under `key`, replacing any earlier value.
    func set(_ value: Data, for key: String) throws(SecretStoreError)
    /// Forgets `key`. Not an error if there was nothing under it.
    func delete(_ key: String) throws(SecretStoreError)
}

/// Why a ``SecretStore`` call failed.
///
/// The cases and their descriptions carry no key and no value, and no
/// system message that might quote one: an error that is logged, reported or
/// shown cannot leak what it was about.
public enum SecretStoreError: Error, Sendable, Hashable, CustomStringConvertible, Retryable {
    /// The key is empty.
    case invalidKey
    /// The value is empty. Use `delete` to remove a secret.
    case invalidValue
    /// The store cannot be read now: the device is locked, or has not been
    /// unlocked since boot and the item needs it; on macOS, the keychain is
    /// locked or there is no UI session to ask the user in
    /// (`errSecInteractionNotAllowed`). The secret may exist.
    case locked
    /// The user declined, or authentication failed: a denied or cancelled
    /// access prompt, a wrong password (`errSecAuthFailed`,
    /// `errSecUserCanceled`). The secret may exist.
    case authenticationFailed
    /// The app is not entitled to the Keychain: unsigned, or missing the
    /// keychain-sharing capability for its access group.
    case missingEntitlement
    /// The Keychain service is unavailable or failed to respond, or there is
    /// no keychain to open. The secret may exist.
    case unavailable
    /// The store returned something that is not the data that was kept.
    case corrupted
    /// Any other Keychain failure, by its `OSStatus`.
    case other(status: Int32)

    public var description: String {
        switch self {
        case .invalidKey: "invalid key"
        case .invalidValue: "invalid value"
        case .locked: "locked"
        case .authenticationFailed: "authentication failed"
        case .missingEntitlement: "missing entitlement"
        case .unavailable: "unavailable"
        case .corrupted: "corrupted"
        case .other(let status): "status \(status)"
        }
    }

    /// A locked device unlocks, and a busy service recovers; nothing else
    /// changes by asking again.
    public var retryDecision: RetryDecision {
        switch self {
        case .locked, .unavailable: .retry
        case .invalidKey, .invalidValue, .authenticationFailed, .missingEntitlement, .corrupted, .other: .stop
        }
    }
}

/// A ``SecretStore`` in memory, for tests: no Keychain, nothing persisted.
///
/// Refuses what the real one refuses (an empty key, an empty value), and can
/// be made to fail so a test can see how the caller copes.
public final class InMemorySecretStore: SecretStore {
    private struct State {
        var values: [String: Data] = [:]
        var failures: [SecretStoreError] = []
        var calls = 0

        /// Counts the call, then fails it if a failure is queued or the key is empty.
        mutating func begin(key: String) throws(SecretStoreError) {
            calls += 1
            if !failures.isEmpty { throw failures.removeFirst() }
            guard !key.isEmpty else { throw .invalidKey }
        }
    }

    private let state: Mutex<State>

    public init(_ values: [String: Data] = [:]) {
        state = Mutex(State(values: values))
    }

    /// The keys held, sorted.
    public var keys: [String] { state.withLock { $0.values.keys.sorted() } }

    /// How many calls were made, failed ones included.
    public var callCount: Int { state.withLock { $0.calls } }

    /// Makes the next call fail with `error`; several queue, one per call.
    /// The failed call changes nothing.
    public func failNext(with error: SecretStoreError) {
        state.withLock { $0.failures.append(error) }
    }

    public func get(_ key: String) throws(SecretStoreError) -> Data? {
        try state.withLock { state throws(SecretStoreError) in
            try state.begin(key: key)
            return state.values[key]
        }
    }

    public func set(_ value: Data, for key: String) throws(SecretStoreError) {
        try state.withLock { state throws(SecretStoreError) in
            try state.begin(key: key)
            guard !value.isEmpty else { throw .invalidValue }
            state.values[key] = value
        }
    }

    public func delete(_ key: String) throws(SecretStoreError) {
        try state.withLock { state throws(SecretStoreError) in
            try state.begin(key: key)
            state.values[key] = nil
        }
    }
}
