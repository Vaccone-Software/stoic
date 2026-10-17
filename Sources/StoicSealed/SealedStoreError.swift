#if STOIC_CRYPTO
public import Stoic
public import StoicStore

/// Why a sealed file or journal call failed: the storage, the seal, the keyring,
/// or a compaction that was done and could not finish its job.
///
/// Each case keeps its cause whole, so a caller still tells a torn tail from a
/// tampered record, a lost key from a refusing keychain, and a full disk from
/// any of them. No case carries a key, a plaintext or a nonce.
public enum SealedStoreError: Error, Sendable, CustomStringConvertible, Retryable {
    /// The file system failed (`StoreError`), including
    /// `.durabilityUnknown`, which means the change *is* in place.
    case store(StoreError)
    /// A value could not be sealed or opened (``SealError``).
    case seal(SealError)
    /// The keyring could not be read or changed (``KeyringError``): when it is
    /// ``CustodyError/unavailable(_:)`` the keys may well exist.
    case keyring(KeyringError)
    /// A compaction refused to run because `count` records or the snapshot
    /// could not be opened, and writing a snapshot without them would destroy
    /// them. Nothing was written. Pass ``SealedJournal/Unreadable/discard`` to
    /// compact anyway, once the loss is accepted.
    case unreadable(count: Int)
    /// The compaction **succeeded**: the snapshot is durable under the new key
    /// and the log is truncated. But the old keys could not be retired, so what
    /// was sealed before is still readable by anyone who can open the keyring;
    /// the shredding is not done. Compact with rotation again, or retire the
    /// keys, once the custody answers.
    case compactedButNotShredded(KeyringError)
    /// An adoption sealed a plaintext file to a staged copy and the copy did not
    /// open to the plaintext it was made from: it failed to open (the
    /// ``SealError``) or opened to other bytes (`nil`). Nothing was replaced: the
    /// plaintext file is as it was, and the staged copy is removed. A cipher or a
    /// disk that does this is not one to seal data with; report it.
    case verificationFailed(SealError?)

    public var description: String {
        switch self {
        case .store(let error): "store: \(error)"
        case .seal(let error): "seal: \(error)"
        case .keyring(let error): "\(error)"
        case .unreadable(let count): "refused to compact: \(count) sealed values cannot be opened and would be lost"
        case .compactedButNotShredded(let error): "compacted, but the old keys were not retired (\(error))"
        case .verificationFailed(let error):
            "the sealed copy did not open to the plaintext it was made from (\(error.map { "\($0)" } ?? "it opened to other bytes")); the plaintext was left as it is"
        }
    }

    public var retryDecision: RetryDecision {
        switch self {
        case .store(let error): error.retryDecision
        case .seal(let error): error.retryDecision
        case .keyring(let error), .compactedButNotShredded(let error): error.retryDecision
        case .unreadable, .verificationFailed: .stop
        }
    }
}
#endif
