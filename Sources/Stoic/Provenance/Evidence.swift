/// What a kind of evidence proves, and the type that controls who may mint
/// it (design/28).
///
/// A conforming type names one fact and its details: `OwnClock` (this
/// process's clock read this moment), `Grant` (a policy allowed this), an
/// app's `Session` (the request carried a live session for this person). Its
/// ``proves`` says, in a sentence, what that is and nothing more, because
/// what code believes a proof shows is the bug provenance exists to stop:
/// a valid signature proves who sent the bytes, never that they are true.
///
/// Declare ``Mint`` as a struct whose only initialiser is `private` or
/// `fileprivate` to the verifier's file. Whoever can construct one can make
/// a ``Minter`` and mint `Verified<_, Self>`; `stoic.evidence-mint-access`
/// refuses a `Mint` anyone else can make.
public protocol Evidence: Sendable {
    /// The token that authorises minting this evidence.
    associatedtype Mint

    /// What this evidence proves, in a sentence, and nothing it does not.
    static var proves: String { get }
}

/// Evidence about who is acting: a person or a service, authenticated.
///
/// Nothing else stands in for it: content evidence says who sent bytes (an
/// app, a key), not who is asking, so a function that needs an authenticated
/// principal takes `Verified<_, some PrincipalEvidence>` and refuses the rest
/// at compile time.
public protocol PrincipalEvidence: Evidence {}

/// Evidence about bytes: where they came from, or that they are intact. A
/// value computed from such bytes came from the same place, so
/// ``Verified/deriving(_:)`` keeps it.
public protocol ContentEvidence: Evidence {}
