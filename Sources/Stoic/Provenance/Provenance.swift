/// A value someone told us: a request's body, a header, a file another
/// program can write, what a person typed. Nobody has vouched for it
/// (design/28).
///
///     struct CheckInBody: Codable {
///         var commitment: Claimed<CommitmentID>      // the wire format is the value's
///         var scannedAt: Claimed<Moment>
///     }
///
/// Anyone may make one, because claiming costs nothing. Getting the value
/// back out is the point of the type: a verifier reads it through its
/// ``Minter``, and anything else calls ``unverified()``, the named escape
/// that `stoic.unverified-claim` counts.
///
/// A claim does not record where it came from: that would be one more field
/// to trust, and the boundary that made it already knows.
///
/// Printing a claim shows its type, not its value (`Claimed<String>`): claims
/// are names, emails and dates of birth, and interpolation is how they reach
/// logs. `debugDescription` shows the value, for a debugger.
public struct Claimed<Value> {
    /// Read only through ``unverified()`` and ``Minter/read(_:)``.
    fileprivate let value: Value

    public init(_ value: Value) {
        self.value = value
    }

    /// A function of a claim is a claim: trimming a claimed string, or
    /// decoding claimed bytes, does not make anyone vouch for it.
    public func map<U, Failure: Error>(_ transform: (Value) throws(Failure) -> U) throws(Failure) -> Claimed<U> {
        Claimed<U>(try transform(value))
    }

    /// The value without proof: the escape. Outside test code,
    /// `stoic.unverified-claim` refuses the call unless a
    /// `// stoic:allow(unverified-claim): <why>` reason is written (and
    /// recorded in the lint baseline). A verifier never needs it: it reads
    /// through its ``Minter``.
    public func unverified() -> Value {
        value
    }
}

extension Claimed: Sendable where Value: Sendable {}
extension Claimed: Equatable where Value: Equatable {}
extension Claimed: Hashable where Value: Hashable {}

extension Claimed: Encodable where Value: Encodable {
    /// Encodes as the value alone: a `Codable` request type can declare a
    /// claimed field and keep its wire format.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

extension Claimed: Decodable where Value: Decodable {
    /// Decodes the value alone: what arrives is always a claim.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(Value.self))
    }
}

extension Claimed: CustomStringConvertible, CustomDebugStringConvertible {
    /// `Claimed<Moment>`: the type, never the value.
    public var description: String { "Claimed<\(Value.self)>" }

    /// `Claimed(<value>)`, for a debugger.
    public var debugDescription: String { "Claimed(\(String(reflecting: value)))" }
}

/// A value, and the evidence that proved it (design/28).
///
///     func accept(_ waiver: WaiverID, at moment: Verified<Moment, OwnClock>,
///                 by parent: Verified<Someone, ParentLink>) async throws
///
/// The evidence's *kind* is in the type, so a function asks for exactly the
/// kind it needs and the compiler refuses any other (a claim, or a moment a
/// device sent); its *details* are in ``evidence``, for the record: which
/// key signed, which policy allowed, when.
///
/// Only a ``Minter`` makes one, and only code that can construct the
/// evidence's `Mint` makes a minter. The one initialiser is `fileprivate` to
/// this file, an extension in another module cannot add one (it would have to
/// delegate to an initialiser it cannot reach), the stored properties are
/// `let`, and the type is not `Decodable`: a proof is never read back from
/// bytes.
///
/// Encoded, it is its value alone, and what decodes on the other side is a
/// claim. Printing one shows the value's type and the evidence kind
/// (`Verified<Moment> by OwnClock`), never the value.
public struct Verified<Value, Evidence: Stoic.Evidence> {
    /// The value the evidence is about.
    public let value: Value
    /// What proved it, and the details of the proof.
    public let evidence: Evidence

    /// The only initialiser: ``Minter/verified(_:_:)`` and ``deriving(_:)``
    /// call it.
    fileprivate init(value: Value, evidence: Evidence) {
        self.value = value
        self.evidence = evidence
    }

    /// The value without its proof, to send or to store: what the other
    /// side gets.
    public var claim: Claimed<Value> { Claimed(value) }
}

extension Verified: Sendable where Value: Sendable {}
extension Verified: Equatable where Value: Equatable, Evidence: Equatable {}
extension Verified: Hashable where Value: Hashable, Evidence: Hashable {}

extension Verified: Encodable where Value: Encodable {
    /// Encodes the value alone. There is no `Decodable`: written down, a
    /// proof is a claim.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

extension Verified: CustomStringConvertible, CustomDebugStringConvertible {
    /// `Verified<Moment> by OwnClock`: the value's type and the evidence
    /// kind, never the value.
    public var description: String { "Verified<\(Value.self)> by \(Evidence.self)" }

    /// `Verified(<value>) by <evidence>`, for a debugger.
    public var debugDescription: String {
        "Verified(\(String(reflecting: value))) by \(String(reflecting: evidence))"
    }
}

extension Verified where Evidence: ContentEvidence {
    /// A value computed from this one, with the same evidence: a body
    /// decoded from attested bytes is still what that sender sent.
    ///
    /// Offered only for content evidence (who sent these bytes, and that they
    /// are intact). A stamped moment plus a day is not what the clock read,
    /// and a grant on one subject is nothing on another, so `OwnClock`,
    /// `Grant` and principal evidence have no `deriving`. The closure must
    /// compute from its input: `stoic.derivation-ignores-input` refuses one
    /// that visibly does not.
    public func deriving<U, Failure: Error>(_ transform: (Value) throws(Failure) -> U) throws(Failure) -> Verified<U, Evidence> {
        Verified<U, Evidence>(value: try transform(value), evidence: evidence)
    }
}

/// The capability to mint `Verified<_, E>`, and to read the claims a verifier
/// checks.
///
///     struct Session: PrincipalEvidence {
///         static let proves = "the request carried a live session token for this person"
///         struct Mint { fileprivate init() {} }        // only this file can mint
///         let sessionID: String
///     }
///     private let minter = Minter<Session>(Session.Mint())
///
/// Making one takes an `E.Mint`, which only the verifier's file can
/// construct, so holding a minter is the verifier's authority. Store it
/// `private` beside the verifier: a minter anyone can reach is a forger
/// anyone can call. It is a value with no state.
public struct Minter<E: Evidence>: Sendable {
    /// A minter for `E`, made with the `Mint` only `E`'s verifier can make.
    public init(_ mint: E.Mint) {}

    /// `value`, proved by `evidence`.
    public func verified<V>(_ value: V, _ evidence: E) -> Verified<V, E> {
        Verified(value: value, evidence: evidence)
    }

    /// The value of a claim this verifier is checking. Not the escape: a
    /// verifier is the code entitled to look.
    public func read<V>(_ claim: Claimed<V>) -> V {
        claim.value
    }
}
