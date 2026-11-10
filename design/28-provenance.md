# 28 · Provenance

> Built in 0.7.0, on design/26 (`Moment`, the ambient wall clock) and design/27
> (lifecycles, whose "Not built" promised principals with provenance in this
> release). design/29 (App Attest) is its first large client. The draft was
> reviewed and amended (what a claim prints; its open questions decided); "As
> built" lists every departure from it.

Most of the facts an app acts on were told to it. A user's age is the date of
birth they typed. A waiver's acceptance time is the device's clock. A check-in's
location is what the phone reported. "Who is asking" is a `userId` argument the
caller chose. Each of these is a claim, and code treats it as a fact because
nothing in its type says otherwise: a `Moment` from the server's clock and a
`Moment` from a request body are the same type, so a function that records when
a waiver was accepted cannot ask for the first and refuse the second. The usual
fix is a convention ("always use the server's time", "always read the identity
from the session"). The bugs come from paths that skip it.

The same confusion runs the other way. Once something is checked, code takes the
check for more than it proved. A valid signature proves who sent the bytes, not
that what they say is true. A decrypted file proves it was sealed with our key,
not that it is the latest version. A permission that is "still loading" gets
read as "denied" in one place and "allowed" in another.

Stoic makes provenance part of a value's type. Data that crosses a trust
boundary is a `Claimed<T>`. Code that needs a fact takes a `Verified<T, E>`.
Only a verifier can make one, and its evidence type `E` names what was proved
and nothing else. A checked permission is one kind of evidence. Writing a value
down loses its proof. And getting a plain value out of a claim without verifying
it is a named escape that the lint plugin counts.

## The ideal scenario

> A volunteering service. A volunteer checks in on site from the app. A minor's
> parent accepts a waiver from an emailed link. A coordinator edits an event.
> The service records who did each thing, when its own clock says it happened,
> and what the device claimed. It never takes a device's word for a fact it can
> establish itself. It never takes a signature for proof of what was signed.
> A person waiting for their permissions sees neither an enabled button nor a
> "not permitted" message.

```swift
import Stoic

// Who is asking: the session token, verified. Never a `userId` argument.
struct Session: PrincipalEvidence {                       // the app's evidence kind
    static let proves = "the request carried a live session token for this person"
    let sessionID: String
    struct Mint { fileprivate init() {} }                 // only this file can mint
}
struct Sessions {
    private static let minter = Minter<Session>(Session.Mint())
    func verify(_ token: Claimed<String>) async throws(AuthError) -> Verified<Someone, Session> {
        let found = try await identity.lookUp(Self.minter.read(token))    // a verifier reads the claim
        return Self.minter.verified(.volunteer(found.userID), Session(sessionID: found.id))
    }
}

// May they: a permission, declared once, decided by a policy. Three answers, never a Bool.
enum CheckIn: Permission {
    typealias Subject = CommitmentID
    typealias Principal = Someone
    static let name = "attendance.check-in"
}
struct CheckInPolicy: PermissionPolicy {
    typealias Granting = CheckIn                             // the permission it decides
    let name = "own-commitment"
    func decide(_ who: Verified<Someone, Session>, _ commitment: CommitmentID) async throws -> PermissionDecision {
        guard let owner = try await commitments.owner(of: commitment) else { return .deny("no such commitment") }
        return owner == who.value ? .allow : .deny("this is someone else's commitment")
    }
}

func checkIn(_ http: IncomingRequest) async throws -> Response {
    let me = try await sessions.verify(Claimed(http.bearerToken))
    // From where: an unmodified build of the app on real hardware sent these bytes (design/29).
    let request = try await attestation.verify(http)              // Verified<AttestedRequest, AppAttested>
    let body = try request.deriving { try CheckInBody.schema.decode($0.body) }
    // `body.value.location` came from a genuine app. A genuine app can be handed a
    // fake location, and the type says only what was proved: `AppAttested`.
    let commitment = try await CheckInPolicy().check(Claimed(body.value.commitment), by: me).granted()

    // Recorded by whom the service authenticated, at the store's moment (design/27).
    try await attendance.apply(.checkIn(closesAt: event.end + hour), to: commitment.value, by: me,
                               because: "checked in from the app")
    try await audit.note(claimedScanAt: Claimed(body.value.scannedAt))   // the device's moment: kept, never trusted
    return .ok
}

// When: the service's own clock. A waiver's acceptance takes one; a device's moment does not compile.
try await waivers.accept(waiverID, at: Moment.stamped(), by: parent)    // parent: Verified<Someone, ParentLink>

func accept(_ waiver: WaiverID, at moment: Verified<Moment, OwnClock>, by parent: Verified<Someone, ParentLink>) async throws

// The app, waiting for roles: not "denied", not "allowed".
switch editCheck {                                            // PermissionCheck<EditEvent>
case .granted(let proof):  Button("Edit") { open(proof) }     // the action takes the proof, not an id
case .denied(let denial):  Text(denial.reason)
case .unknown:             ProgressView()
}
```

## Origin

- **Kindora** (TypeScript on Convex), read for this contract. Facts with legal
  weight are taken from the client:
  - A waiver's `acceptedTime` is an argument. `signRegisteredWaivers`
    (`commitments/mutations.ts:328`) stores `w.acceptedTime ?? Date.now()`: the
    device's clock first, the server's only if the device sent nothing.
  - A guest's age comes from a `dateOfBirth` string the client sends
    (`guestCommitments/mutations.ts:27`), parsed by `utils/age.ts` with the
    server's local calendar.
  - Check-in location arrives as `latitude`/`longitude` arguments
    (`commitments/mutations.ts:125`, `:216`). The radius check is right, and it
    runs on numbers the phone chose.
  - Identity is passed in. `signRegisteredWaivers` takes `userId`, `email`,
    `firstName`, `lastName` as arguments. `createByUserIdMutation`
    (`permissions/mutations.ts:37`), commented "for internal use only", is a
    public mutation that grants any `userId` every permission on any charity.
  - Of the 62 public functions (42 `mutation`s, 20 `action`s), about 52 never
    ask who is calling. Ten files call `getCurrentUserId` or `getUserIdentity`;
    the rest trust their arguments.
  - The UI reads a permission that has not loaded yet as "not permitted".
- **Alexis King, "Parse, don't validate"** (design/06): a checked value should
  have a type that says it was checked. Provenance applies the same rule to
  where a value came from and who vouches for it, not to its shape.
- **JWT libraries that hand back claims before checking the signature**
  (`decode` beside `verify`, `alg: none`). This is the standard way a verified
  value gets confused with a parsed one. Here the parsed value is a `Claimed`.
- **Object capabilities** (the E language; Miller, Yee and Shapiro, "Capability
  Myths Demolished"): authority is a reference you cannot forge, not a check you
  can forget to make. `Granted<P>` is a capability to act on one subject.
- **Phantom-typed tags** (Haskell's `Tagged`, Rust newtypes with private
  constructors): the type carries a fact the compiler enforces, at no run-time
  cost.
- **Stoic's own escapes.** `Secret.reveal()` is explicit and easy to find in
  review. `stoic:allow` takes a reason and is counted in the baseline (design/13).
  The escape here works the same way.

## What provenance does not do

- **It never proves that content is true.** No evidence kind in Stoic says "this
  is true", and none ever will. The strongest proves that bytes came from a
  particular sender and were not altered. A genuine app can be given a fake
  location, and a person can lie about their date of birth.
- **It is not a security boundary against code in the same module as a
  verifier.** Access control decides who can mint a proof. Code that may call a
  verifier's minter can mint anything (see Minting).
- **It does not cross a process.** A proof is a value in memory. Sent, stored or
  encoded, it becomes a claim, unless what is stored is itself evidence that a
  verifier can check again (see Writing down).
- **It is not a policy language.** Stoic ships the shape of a permission check:
  a declared permission, a policy the app writes, and three outcomes. It does
  not ship roles, attributes, rule engines or a decision language (Not built).

## Rules

1. **At a trust boundary, a value is a claim.** Request bodies, query
   parameters, headers, files, another process's messages, and values read back
   from storage enter as `Claimed<T>`, or as plain values that the code at the
   boundary does not treat as facts.
2. **A function that needs a fact takes a `Verified<T, E>`, with the narrowest
   `E` that is enough.** It takes a `Granted<P>` in place of the id it acts on,
   so a proof for one subject cannot be paired with another.
3. **Only a verifier mints.** The compiler enforces this: a `Verified<_, E>` is
   made only through a `Minter<E>`, and only code that can construct `E.Mint` can
   make one. Every `Mint` initialiser is `private` or `fileprivate`
   (`stoic.evidence-mint-access`).
4. **A claim's value comes out through a verifier, or through `unverified()`.**
   `unverified()` is the escape. Outside test code, `stoic.unverified-claim`
   refuses it unless a `stoic:allow` reason is written and recorded in the
   baseline.
5. **Evidence says what was proved, and nothing more.** Content evidence (who
   sent these bytes, and that they are intact) carries over to values derived
   from those bytes. Time and permission evidence do not. The evidence that
   authenticates a person (`PrincipalEvidence`) is its own kind, and nothing
   else stands in for it.
6. **Unknown is not an answer.** A permission check has three outcomes, and none
   of them turns into a `Bool`.

## API

```swift
// MARK: Stoic (the kernel), Sources/Stoic/Provenance. Standard library only.

/// A value someone told us. Anyone may make one: claiming costs nothing.
public struct Claimed<Value> {
    public init(_ value: Value)
    /// A function of a claim is a claim.
    public func map<U, Failure: Error>(_ transform: (Value) throws(Failure) -> U) throws(Failure) -> Claimed<U>
    /// The value without proof: the escape (`stoic.unverified-claim`).
    public func unverified() -> Value
}
extension Claimed: Sendable where Value: Sendable {}
extension Claimed: Equatable where Value: Equatable {}
extension Claimed: Hashable where Value: Hashable {}
extension Claimed: Encodable where Value: Encodable {}      // as the value alone
extension Claimed: Decodable where Value: Decodable {}      // as the value alone
extension Claimed: CustomStringConvertible, CustomDebugStringConvertible  // "Claimed<T>"; debugDescription shows the value

/// What a kind of evidence proves, and the type that controls who may mint it.
public protocol Evidence: Sendable {
    /// Whoever can construct one can mint `Verified<_, Self>`. Declare it as a
    /// struct whose only initialiser is `private` or `fileprivate` to the verifier.
    associatedtype Mint
    /// What this evidence proves, in a sentence, and nothing it does not.
    static var proves: String { get }
}
/// Evidence about who is acting: a person or a service, authenticated.
public protocol PrincipalEvidence: Evidence {}
/// Evidence about bytes: where they came from, or that they are intact. A value
/// computed from such bytes came from the same place (`deriving`).
public protocol ContentEvidence: Evidence {}

/// A value, and the evidence that proved it. Made only by a `Minter`.
public struct Verified<Value, Evidence: Stoic.Evidence> {
    public let value: Value
    public let evidence: Evidence
    /// The value without its proof, to send or store: what the other side gets.
    public var claim: Claimed<Value> { get }
}
extension Verified: Sendable where Value: Sendable {}
extension Verified: Equatable where Value: Equatable, Evidence: Equatable {}
extension Verified: Hashable where Value: Hashable, Evidence: Hashable {}
extension Verified: Encodable where Value: Encodable {}     // the value alone. Never Decodable.
extension Verified: CustomStringConvertible, CustomDebugStringConvertible // "Verified<T> by <Evidence>"; debugDescription shows the value
extension Verified where Evidence: ContentEvidence {
    /// A value computed from this one, with the same evidence (`stoic.derivation-ignores-input`).
    public func deriving<U, Failure: Error>(_ transform: (Value) throws(Failure) -> U) throws(Failure) -> Verified<U, Evidence>
}

/// The capability to mint `Verified<_, E>` and to read the claims a verifier checks.
public struct Minter<E: Evidence>: Sendable {
    public init(_ mint: E.Mint)
    public func verified<V>(_ value: V, _ evidence: E) -> Verified<V, E>
    public func read<V>(_ claim: Claimed<V>) -> V
}

// Time: a moment from this process's own wall clock.
public struct OwnClock: Evidence, Hashable {                // Mint is fileprivate to the kernel
    public static let proves = "this process's wall clock read this moment when the value was made"
}
extension Moment {
    public static func stamped() -> Verified<Moment, OwnClock>      // Ambient.current.wallClock.now
}

// Permissions: the pattern, not a policy language.
public protocol Permission: Sendable {
    associatedtype Subject: Hashable & Sendable            // what it is about: an event's id
    associatedtype Principal: Hashable & Sendable          // who asks
    static var name: String { get }                         // stable: in grants and events
}
public protocol PermissionPolicy<Granting>: Sendable {
    associatedtype Granting: Permission
    associatedtype Authentication: PrincipalEvidence
    var name: String { get }                                // recorded in every grant
    func decide(_ principal: Verified<Granting.Principal, Authentication>,
                _ subject: Granting.Subject) async throws -> PermissionDecision
}
extension PermissionPolicy {
    /// The only producer of a `Granted<Granting>`. Throws nothing but cancellation.
    public func check(_ subject: Claimed<Granting.Subject>,
                      by principal: Verified<Granting.Principal, Authentication>) async throws(CancellationError) -> PermissionCheck<Granting>
}
public enum PermissionDecision: Sendable, Hashable { case allow, deny(String), unknown(PermissionUnknown) }
public enum PermissionUnknown: Sendable, Hashable { case loading, unavailable(String) }
public enum PermissionCheck<P: Permission>: Sendable {
    case granted(Granted<P>)
    case denied(PermissionDenial<P>)
    case unknown(PermissionUnknown)
    /// For a handler that must act or fail: denied and unknown throw, told apart.
    public func granted() throws(PermissionRefusal<P>) -> Granted<P>
}
public struct Grant<P: Permission>: Evidence, Hashable {   // Mint is fileprivate to the kernel
    public static var proves: String { get }               // "<policy> allowed <principal> <P.name> on this subject at <decidedAt>"
    public let principal: P.Principal
    public let policy: String
    public let decidedAt: Moment
}
public typealias Granted<P: Permission> = Verified<P.Subject, Grant<P>>
public struct PermissionDenial<P: Permission>: Sendable, Hashable {
    public let subject: P.Subject; public let principal: P.Principal; public let policy: String; public let reason: String
}
public enum PermissionRefusal<P: Permission>: Error, Sendable, Hashable, Retryable {
    case denied(PermissionDenial<P>)                        // .stop: answer 403
    case unknown(PermissionUnknown)                         // .retry: answer 503, never 403
}

// Lifecycles (design/27): a verified principal, recorded as its value.
extension LifecycleStore {
    public func apply<E: PrincipalEvidence>(_ event: Definition.Event, to id: ID, by principal: Verified<Definition.Principal, E>,
                                            because: String) async throws(LifecycleUpdateError<Definition, Failure>) -> Definition.Record
}

// MARK: StoicTesting

/// A principal for tests, minted on request. StoicTesting is never linked into an app.
public struct TestPrincipal: PrincipalEvidence, Hashable { public static let proves = "a test said so" }
public enum TestProof {
    public static func principal<P>(_ principal: P) -> Verified<P, TestPrincipal>
}

// MARK: StoicSealed (trait Crypto)

public struct AuthenticatedDecryption: ContentEvidence, Hashable {   // Mint is fileprivate to Sealing.swift
    public static let proves = "these bytes were sealed for this context under a key this keyring holds, and are unchanged"
    public let key: KeyID
    public let purpose: String
}
extension Sealing {
    /// `open`, as a verification. Throws what `open` throws.
    public static func verify(_ sealed: Claimed<[UInt8]>, context: SealContext, keyring: Keyring)
        throws(SealError) -> Verified<[UInt8], AuthenticatedDecryption>
}

// MARK: StoicLintCore: three rules (below).
```

## Semantics

### Claims

A `Claimed<T>` is a value plus one fact about it: nobody has vouched for it.
Making one is free and public. The boundary that receives data is the place to
make one: a server decoding a request body, a host decoding an XPC message, a
reader of a file another program can write. A claim is `Codable` exactly as its
value is, so a `Codable` request type can declare `var acceptedAt: Claimed<Moment>`,
and the wire format does not change.

A claim does not record where it came from. That would be one more field to
trust, and the boundary that made it already knows. Verifiers report their own
refusals.

`map` turns a claim into another claim: trimming a string or decoding claimed
bytes is still a claim.

**A claim does not print its value.** Claims are what people typed and what
requests carried: names, emails, dates of birth. String interpolation is how
such values reach logs. So `description` is `Claimed<TypeName>`, and
`debugDescription` (what a debugger shows) has the value. Events already treat
strings as private by default; this is the same rule. A display of what a
person typed reads the value through `unverified()` with its reason, which is
the escape doing its job. `Verified` likewise: `description` names the value's
type and the evidence kind (`Verified<Moment> by OwnClock`), never the value.

### Verified values

A `Verified<T, E>` is a value and an `E`: the evidence kind is in the type, and
the details are in the value. A function asks for the kind it needs:
`Verified<Moment, OwnClock>` rejects a `Verified<Moment, AppAttested>`, which in
turn rejects a `Claimed<Moment>`. The details are there for the record: which key
signed it, which policy allowed it and when.

**Why both a type and a value.** With a type parameter alone ("phantom"), the
compiler could check the kind, but nothing would record which key, policy or
moment did the proving, and a proof could not be audited. With a value alone,
every function would have to check at run time that it had been handed the right
kind, and a mistake would compile. Carrying the evidence as a typed value gives
one name for both. The cost is the size of the evidence value: a few words
(`OwnClock` is empty).

### Evidence, and what each kind proves

| Evidence                     | Kind       | Proves                                                                                                                                      | Does not prove                                                                              | Made by                       | In 0.7 |
| ---------------------------- | ---------- | ------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- | ----------------------------- | ------ |
| `OwnClock`                   | time       | this process's wall clock read this moment                                                                                                  | that the clock was right; anything about another process's clock                            | `Moment.stamped()`            | yes    |
| `Grant<P>`                   | permission | the named policy allowed this principal `P` on this subject, at `decidedAt`                                                                 | that it still would; anything on another subject                                            | `PermissionPolicy.check`      | yes    |
| an app's `PrincipalEvidence` | principal  | what the app's verifier says (a live session, a signed link)                                                                                | whatever the app's `proves` leaves out                                                      | the app's verifier            | yes    |
| `AuthenticatedDecryption`    | content    | sealed for this context under a key the ring holds; unchanged since                                                                         | who sealed it (anything holding the key); when; that it is the latest (rollback, design/24) | `Sealing.verify`              | yes    |
| `AppAttested` (design/29)    | content    | signed by an App Attest key that Apple certified, for an unmodified instance of this app on genuine hardware; unaltered; the counter is new | who the user is; that the content is true; that the device is not a farm                    | `AppAttest.verifyRequest`     | yes    |
| `KeyAttested` (design/29)    | key        | Apple certified this public key for this app id and environment                                                                             | anything about later requests                                                               | `AppAttest.verifyAttestation` | yes    |
| `BundledService` (StoicXPC)  | content    | the bytes came from a process launchd started from this app's `Contents/XPCServices/<name>`                                                 | the service's build beyond its own word; an unsigned bundle's integrity                     | the handshake                 | later  |
| `TLSOrigin` (StoicHTTP)      | content    | the response came from the base origin, over TLS the system's trust evaluation accepted                                                     | that the server's content (a `Date` header, a balance) is true                              | `HTTPClient`                  | later  |

`PrincipalEvidence` and `ContentEvidence` are marker protocols that the compiler
reads. `AppAttested` is content evidence and not principal evidence, so passing
an attested request where a person must be authenticated does not compile. App
Attest says nothing about the user, and the type agrees. `OwnClock` and `Grant`
are neither, so nothing can be derived from them.

### Minting: how a proof is unforgeable, in Swift 6.4

The guarantee is access control, enforced by the compiler:

- `Verified` has stored `let` properties and one initialiser, `fileprivate`, in
  the file that also declares `Minter`. Its memberwise initialiser is not
  synthesised, because an explicit one exists. `Minter.verified(_:_:)` is the
  only way to call it, from inside Stoic or out.
- An extension of `Verified` in another module cannot add an initialiser that
  sets its properties. Swift requires a struct's initialiser in another module
  to delegate to `self.init`, and none is reachable.
- `Verified` is not `Decodable`. Decoding one does not compile, and neither does
  a `Decodable` type with a `Verified` property.
- `let` properties have no `WritableKeyPath`, and a `Mirror` can read but not
  write. A `var` copy of a `Verified` cannot change its value or its evidence.
- `Minter<E>.init` takes an `E.Mint`. For Stoic's own evidence kinds (`OwnClock`,
  `Grant`, `AuthenticatedDecryption`, `AppAttested`, `KeyAttested`), `Mint` has
  a `fileprivate init()` in the one file that verifies. Even `@testable import`,
  which exposes `internal` declarations, cannot reach them.
- An app's evidence kind does the same: `struct Mint { fileprivate init() {} }`
  in the verifier's file. A `Mint` with a default (internal) or `public`
  initialiser is refused by `stoic.evidence-mint-access`.
- Copying a real proof's evidence onto another value
  (`minter.verified(other, proof.evidence)`) still needs a `Minter<E>`, so the
  only code that can do it is the verifier.

**What a determined author can still do**, all visibly:

1. Mint anything in the file (or, with a non-private `Mint`, the module) that
   can construct `E.Mint`. That is the verifier's trust, by design.
2. Launder: write a public function in the verifier's module that mints on
   demand, or store a `Minter` where other code can reach it. Review catches
   this; the compiler cannot.
3. Smuggle a claim's value out through a side effect of `Claimed.map`'s closure
   (`claim.map { leaked = $0 }`), or parse it back from `description`. Both are
   plain code a reviewer can see. A lint rule cannot follow them.
4. Ignore the input in `deriving` (`proof.deriving { _ in forged }`).
   `stoic.derivation-ignores-input` catches the literal `_ in` form, not a
   closure that reads its parameter and returns something else.
5. Declare a forgeable evidence kind (a `Mint` with an open initialiser,
   `typealias Mint = Void`) and pass it where a function accepts any evidence of
   a protocol. It forges only its own kind, never Stoic's or another module's,
   and a function that names a concrete kind refuses it.
6. Bypass the type system: `unsafeBitCast` to `Verified`, or
   `@_private(sourceFile:) import` with `-enable-private-imports` to reach a
   `fileprivate` `Mint`. Both need `unsafe` or a compiler flag. Under
   `.strictMemorySafety()` the first is a diagnostic. The second shows in a
   manifest.

So a proof means "a verifier made this, or someone with the verifier's
authority wrote code a reviewer can find". That is the same guarantee
`Refined`'s private initialiser gives a validated value (design/06).

### Deriving

A value computed from verified bytes came from the same place. So for
`ContentEvidence`, `deriving` keeps the evidence: an attested request's body,
decoded, is `Verified<CheckInBody, AppAttested>`. That value is "what the genuine
app sent", and a field of it is still only what the app sent, never true for
that reason alone. Derivation is not offered for time (a stamped moment plus a
day is not what the clock read), for grants (a grant on one subject is nothing
on another), or for principals (relabelling a volunteer as staff is not
authentication). The closure must compute from its input. The lint rule refuses
one that ignores it syntactically.

### Permissions

A permission is a caseless enum that names a subject type, a principal type and
a stable name. A policy decides it, and the app writes the policy as ordinary
async code that can read its database. Stoic writes the check, which is the only
code that mints `Grant`:

- **The principal must be verified.** The policy receives
  `Verified<Principal, Authentication>`, where `Authentication` is a
  `PrincipalEvidence` the policy declares. Kindora's "`userId` as an argument"
  does not compile.
- **The subject is a claim, and the check is its verifier.** `check` takes a
  `Claimed<Subject>`, usually an id from the request. A granted check returns
  `Verified<Subject, Grant<P>>`. The action then takes that one value as both its
  target and its authority. There is no separate id parameter to get wrong.
- **Three outcomes.** `.granted(proof)`, `.denied(denial)` with the policy's
  reason, and `.unknown(.loading | .unavailable(why))`. `PermissionCheck` has no
  `Bool` property and does not convert to one. A view switches on it, so
  "loading" must be drawn as something. A policy that throws gives
  `.unknown(.unavailable(<error type>))`, with `permission.unknown` reported at
  notice level and the error's type recorded. Cancellation is not an outcome:
  `check` throws `CancellationError`, and nothing else.
- **On a server, `granted()`** throws `PermissionRefusal.denied`, which
  classifies `.stop` and means 403, or `.unknown`, which classifies `.retry` and
  means 503. An unknown answer is never sent as a refusal.
- **A grant is a record of a decision.** `decidedAt` says when it was made. It
  does not expire by itself, and nothing in Stoic revokes it. A server checks per
  request, and a grant does not outlive the request. A client holds grants to
  draw its screen. They are advisory and never cross to the server: encoded, a
  `Granted<P>` is only its subject's id, and the server checks again.
- **Stoic ships no policies,** no roles and no rules (Not built). The pattern is
  what makes an unchecked call fail to compile. What a policy allows is the app's
  business, in one place per permission.

### Writing down

Provenance does not survive being written down, because what is written can be
written by someone else.

- **`Codable`.** `Verified` encodes as its value alone and does not decode. A
  type with a `Verified` field can be `Encodable` but not `Decodable`, so stored
  records hold plain values or `Claimed` ones. The protection is at the write
  API: `accept(_:at: Verified<Moment, OwnClock>, by:)` accepts no device moment,
  and stores `at.value`. What is read back is the store's word. It is as
  trustworthy as the store's access control, and the type does not pretend
  otherwise.
- **`StoicSchema`.** A schema proves shape: a `Refined` value is well formed.
  Provenance is a separate question, about who vouches for it. A
  `Claimed<Refined<…>>` is a well-formed claim, and verifiers usually want their
  input refined first, so the schema runs before provenance is asked. `StoicSchema`
  cannot see the kernel, so it has no native `Claimed` leaf. A boundary decodes
  `T` through its schema and wraps it (`Claimed(decoded)`). A `Codable` graph can
  use `Schema.codable(Claimed<T>.self, examples:)`. `Verified` has no schema,
  because a schema decodes.
- **`StoicSealed`.** Opening a sealed value is a verification. `Sealing.verify`
  returns the plaintext as `Verified<[UInt8], AuthenticatedDecryption>`, and
  `deriving` decodes it. What comes back is `AuthenticatedDecryption`, not the
  evidence the value had when it was sealed. A stamped moment sealed and opened
  again is "bytes sealed by a holder of our key", not "our clock read this". An
  older sealed file put back by someone with write access verifies just as well
  (design/24's rollback limit).
- **Stored evidence**, which a verifier can check again later, is the exception
  the rule allows. An App Attest assertion kept with the bytes it signed is one,
  and so is a value sealed with the evidence kind it had (`Resealed<E>`). Both are
  later (Not built).

### The escape

`claim.unverified()` returns the value, and only its name says it was not
verified. Outside test code, `stoic.unverified-claim` reports every call as a
finding. A `// stoic:allow(unverified-claim): <why>` comment silences one, and the
escape budget records it in the baseline (design/13). A new one is then a
reviewed diff. Legitimate uses exist: a display of what a person typed, a value
the app decides to take on trust ("the guest's date of birth: we cannot check
it, and the waiver says so"). The reason says which. A verifier never needs the
escape: `Minter.read` is how it looks at what it verifies.

### Where each piece lives

- **The kernel**, `Sources/Stoic/Provenance`: `Claimed`, `Verified`, `Evidence`
  and its two markers, `Minter`, `OwnClock` with `Moment.stamped()`, and the
  permission pattern. They need nothing but the standard library. Lifecycles,
  operations and every other library need them, and the kernel is never split
  (DESIGN.md, Architecture). This adds about 400 lines and no dependency.
- **`StoicTesting`**: `TestPrincipal` and `TestProof`, a principal minted on
  request for tests of code that needs one. It lives in a module never linked
  into an app. Code that names its real evidence kind (`Session`) refuses it.
- **`StoicSealed`**: `AuthenticatedDecryption` and `Sealing.verify`, beside the
  cipher that does the proving.
- **`StoicLintCore`**: the three rules.
- **`StoicAttestation`, `StoicApple`, `StoicHTTP`**: design/29.

### Three producers, and which are in this release

| Producer                                  | Shape                                                                                                                                                                                                                                                                                                                   | Release |
| ----------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- |
| `StoicSealed`'s open                      | `Sealing.verify(_:context:keyring:) -> Verified<[UInt8], AuthenticatedDecryption>`, beside `open`, which is unchanged                                                                                                                                                                                                   | **0.7** |
| A `Moment` from this process              | `Moment.stamped() -> Verified<Moment, OwnClock>`                                                                                                                                                                                                                                                                        | **0.7** |
| `StoicXPC`'s build handshake              | `XPCPeer.run` as `Verified<XPCRun, BundledService>`: launchd lets only the containing app connect to a bundled service (design/25, rule 1), so the peer's origin is authenticated by the system, and its `build` is that code's own word. On the host, each request's context gains the same evidence about the client. | later   |
| A `Moment` from a server                  | an HTTP `Date` header from the base origin as `Verified<Moment, TLSOrigin>`. That evidence is about content: who said it, over TLS. Whether to trust that server's clock is the app's choice, so it is never `OwnClock`.                                                                                                | later   |
| `SealedFile.read`, `SealedJournal.replay` | `Verified` plaintexts, as `Sealing.verify` does for a value                                                                                                                                                                                                                                                             | later   |
| `StoicHTTP` responses                     | `send(…, decoding:)` returning `Verified<T, TLSOrigin>`: changes every call site                                                                                                                                                                                                                                        | later   |

The 0.7 changes are additive: no existing signature changes. The later ones
change existing APIs, or need evidence kinds whose wording should come from use.

### Lifecycles

design/27's `by:` records a principal. The new `apply` overload takes a
`Verified<L.Principal, some PrincipalEvidence>` and records its value. History
read back is the store's record of who the service authenticated at the time:
data, not a proof. The plain `by: L.Principal` overload stays. A device's
principals (`.updater`, `.watchdog`) are the code itself, and no verifier stands
between them and the store.

### Cancellation

The types are values, and nothing about them waits. `check` checks for
cancellation before the policy runs and after it returns, and throws
`CancellationError` either way. A policy cancelled mid-read throws, and the
check reports that as cancellation, not as `.unknown`. `Sealing.verify` is
synchronous. Cleanup has nothing to do.

### Isolation

`Claimed` and `Verified` are `Sendable` when their value is. Evidence is always
`Sendable`. A policy is `Sendable` and runs on the caller's executor
(`nonisolated(nonsending)`, as Stoic's operation closures do). A `Minter` is a
`Sendable` value with no state.

### Defaults

There are none to choose. The only number is the permission events' level:
`granted` debug, `denied` info, `unknown` notice. A denial is the system
working, and an unknown is something to look at.

## Lint rules

| Id                               | Flags                                                                                                                                                                                                                   | Why                                                                                  | Instead                                                                                       |
| -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------- |
| `stoic.unverified-claim`         | A call `.unverified()` with no arguments, outside test code                                                                                                                                                             | A claim used as a fact without a verifier: the bug provenance exists to make visible | A verifier; or `stoic:allow(unverified-claim): why this claim may be taken as it is`          |
| `stoic.evidence-mint-access`     | In a type whose inheritance clause names `Evidence`, `PrincipalEvidence` or `ContentEvidence`: a nested `Mint` with no initialiser, an `internal`/`package`/`public`/`open` initialiser, or `typealias Mint =` anything | A `Mint` anyone can make lets anyone mint that evidence                              | `struct Mint { fileprivate init() {} }` in the verifier's file; or justify with `stoic:allow` |
| `stoic.derivation-ignores-input` | `.deriving { _ in … }`, or a closure that names no parameter and never uses `$0`                                                                                                                                        | A value with real evidence and invented content                                      | Compute from the input; for a new value, verify it                                            |

All three are syntactic, as every Stoic rule is (design/13). Known false
negatives: `unverified-claim` does not see a method reference
(`let f = claim.unverified`); `evidence-mint-access` does not see a conformance
added in an extension in another file, or a `Mint` declared outside the type;
`derivation-ignores-input` does not see a closure that reads its parameter and
returns something else.

## Failure modes

| What happens if…                                                                         | Then                                                                                                                                |
| ---------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| a claim is passed where a function needs a verified value                                | it does not compile                                                                                                                 |
| code outside a verifier constructs a `Verified`                                          | it does not compile: the only initialiser is `fileprivate`, and minting needs the evidence's `Mint`                                 |
| a real proof's evidence is put on another value                                          | it does not compile outside the verifier: `minter.verified` needs a `Minter`, which needs a `Mint`                                  |
| one evidence kind is passed where another is required                                    | it does not compile                                                                                                                 |
| content evidence (an attested request) is passed where a principal must be authenticated | it does not compile: `AppAttested` is not `PrincipalEvidence`                                                                       |
| a verified value is decoded                                                              | it does not compile: `Verified` is not `Decodable`                                                                                  |
| a verified value is encoded and decoded again                                            | the bytes are the value's; they decode as `Claimed<T>` (or a plain `T`), never as a proof                                           |
| a `Decodable` record declares a `Verified` property                                      | it does not compile; the record holds the plain value or a claim                                                                    |
| a claim's value is read outside a verifier                                               | only through `unverified()`, which `stoic.unverified-claim` refuses without a recorded reason                                       |
| an evidence kind's `Mint` can be made outside its verifier's file                        | `stoic.evidence-mint-access` refuses it                                                                                             |
| a test imports a Stoic module with `@testable`                                           | it cannot mint Stoic's evidence: every Stoic `Mint` initialiser is `fileprivate`                                                    |
| a derivation ignores its input                                                           | `stoic.derivation-ignores-input` refuses the `_ in` form                                                                            |
| a stamped moment, a grant or a principal is derived into another value                   | it does not compile: `deriving` exists only for content evidence                                                                    |
| a check's policy has not loaded                                                          | `.unknown(.loading)`; there is no `Bool` to read it as                                                                              |
| a policy throws                                                                          | `.unknown(.unavailable(<error type>))`; `permission.unknown` at notice; on a server, `granted()` throws `.unknown`, `.retry`, a 503 |
| a policy denies                                                                          | `.denied` with the policy's reason; `permission.denied` at info; `granted()` throws `.denied`, `.stop`, a 403                       |
| a policy allows                                                                          | `.granted(proof)`: the subject, with principal, policy and moment; `permission.granted` at debug                                    |
| the caller is cancelled during a check                                                   | `check` throws `CancellationError`; no outcome is produced or reported                                                              |
| an unauthenticated principal is offered to a check                                       | it does not compile: the policy takes `Verified<Principal, some PrincipalEvidence>`                                                 |
| a grant for one subject is used to act on another                                        | it cannot be: the grant's value is its subject, and the action takes the grant in place of an id                                    |
| a grant made on a device is sent to the server                                           | it arrives as its subject's id, a claim; the server checks again                                                                    |
| a permission is revoked while a grant is held                                            | the grant stays a true record of the decision at `decidedAt`; a server holds none past its request                                  |
| a sealed value is verified                                                               | `Verified<[UInt8], AuthenticatedDecryption>`, or the `SealError` `open` would throw                                                 |
| an older sealed copy replaces the newer one                                              | it verifies: `AuthenticatedDecryption` does not prove freshness                                                                     |
| a stamped moment is read from a clock that is wrong                                      | it is `OwnClock`'s reading, as the type says; a lifecycle clamps a backwards entry (design/27)                                      |
| a device's moment arrives in a request                                                   | it is `Claimed<Moment>`; a write that needs `Verified<Moment, OwnClock>` takes `Moment.stamped()` and may keep the claim beside it  |
| a lifecycle event is applied by a verified principal                                     | the principal's value is recorded in the entry; reading history back gives a record, not a proof                                    |
| a test needs an authenticated principal                                                  | `TestProof.principal(_:)`; code that names its real evidence kind refuses `TestPrincipal`                                           |
| a claimed value has the wrong shape                                                      | its schema refuses it at the boundary (design/06), before any verifier is asked                                                     |

## Events

All in `EventCatalog`, labelled with the permission's `name`. They carry the
policy's name publicly, and the subject and principal as descriptions at
`.private` privacy. They never carry a reason (a reason can name a person). The
denial's reason goes to the caller, which decides what to show.

| Event                | Level  | Meaning                                                        |
| -------------------- | ------ | -------------------------------------------------------------- |
| `permission.granted` | debug  | a policy allowed: policy, how long it took                     |
| `permission.denied`  | info   | a policy denied: policy                                        |
| `permission.unknown` | notice | no decision: `loading`, or `unavailable` with the error's type |

`Claimed`, `Verified`, `Minter` and `Sealing.verify` record nothing. They are
values and pure functions. Sealed storage's own events stand.

## Testing

- **Compile-fail cases** in `scripts/compile-fail` (design/12's harness, which
  `CompileFailTests` runs): constructing `Verified` directly; minting `OwnClock`
  and `Grant` from outside the kernel; decoding a `Verified`; a `Decodable`
  struct with a `Verified` field; passing a `Claimed<Moment>` and a
  `Verified<Moment, AuthenticatedDecryption>` where `Verified<Moment, OwnClock>`
  is required; `deriving` on `OwnClock` and on `Grant`; `if check { }` and
  `check == .granted` on a `PermissionCheck`; a policy whose `Authentication` is
  `AuthenticatedDecryption` (not `PrincipalEvidence`); an extension initialiser
  on `Verified` in another module. A control file uses every public API and must
  compile.
- **Every row above** that can run at run time, on `TestClock` with the test
  wall clock: the three outcomes, a throwing policy, cancellation before and
  during `decide`, `granted()`'s classification, grants' fields, `stamped()` under
  `jumpWallClock`, `Sealing.verify` against every `SealError` case, the encode and
  decode round trip as `Claimed`, and the lifecycle overload against
  `InMemoryLifecycleStore`.
- **Lint**: each rule's findings and non-findings from inline sources, in
  `StoicLintCoreTests`, with the known false negatives written as tests that
  expect nothing.
- **The ideal scenario** as a test: Kindora's check-in, waiver and edit flows on a
  scripted request, with an attested body from design/29's stand-in.

## Not built

- **A policy language, roles or attributes.** A role table or a rule engine is
  data the app chooses. The pattern lets an app's policy be any code, and keeps
  it in one place per permission.
- **Evidence that survives storage**: `Resealed<E>`, a value sealed together
  with the evidence kind it had, which opens as `Verified<_, Resealed<E>>`
  (sealing would take a `Verified`, so only a real proof can be sealed). Also an
  App Attest assertion kept for audit and verified again later without its
  counter.
- **The later producers** above: the XPC handshake, `TLSOrigin` responses, sealed
  file and journal reads.
- **A native `Schema<Claimed<T>>`.** `StoicSchema` cannot see the kernel (Open
  questions).
- **Combining proofs** (`Verified<(A, B), Both<E1, E2>>`). Pass two values.
- **Run-time accounting of escapes.** `unverified()` records nothing, and the
  lint baseline is the count. A debug event per call would cost a record on
  every display of a claim.

## Decisions

The draft's open questions, as the review settled them.

1. **No trusted store.** Values read back from the service's own database are
   claims. An evidence kind such as `StoredByThisService`, minted by a store
   adapter, would be the escape with a nicer name: it proves only what the
   database's access control proves. There is none.
2. **The types stay in the kernel.** `StoicSchema` therefore cannot produce a
   `Claimed` leaf; a boundary decodes through its schema and wraps the result.
   A standalone `StoicProvenance` module would have been the kernel's first
   dependency, and a piece split off it.
3. **Lifecycles do not require a verified principal.** The `apply` overload that
   takes one is the offer. A run-time refusal of the plain overload would be
   weaker than a type, and a second store protocol heavier.
4. **A claim's `description` does not show its value** (the review's amendment):
   see Claims.
5. **`PermissionPolicy.decide` stays as drafted.**

## As built

Departures from the reviewed draft, and decisions it left open.

- **A policy names its permission** (`typealias Granting = CheckIn`). Swift
  cannot infer `Granting` from `decide`, whose parameters mention only
  `Granting.Principal` and `Granting.Subject`, so the draft's policy, written
  without it, does not compile. The ideal scenario above has the line.
- **`check` and `decide` are `nonisolated(nonsending)`**, written out, so a
  policy runs on the caller's executor whatever the app's language mode.
- **A policy that throws while the caller is cancelled** is cancellation, as
  the draft says. One that throws while the caller is not cancelled, even a
  `CancellationError` of its own making, is `.unknown(.unavailable(<type>))`:
  only the caller's cancellation is cancellation.
- **`permission.unknown`** carries `unknown` (`loading` or `unavailable`)
  publicly, and, for a policy that threw, the error's type publicly. A reason
  the policy returned in `.unavailable(_:)` is its own words and is not
  recorded, as a denial's reason is not.
- **`Grant.decidedAt`** is the ambient wall clock's moment when the policy
  answered; `permission.granted`'s duration is measured on the ambient
  (monotonic) clock.
- **`Grant.proves`** is static, so it names the permission
  (`P.name`) and not the policy or the moment, which are the grant's fields.
- **`AuthenticatedDecryption`** carries the key that opened the bytes and the
  purpose of the context, as drafted. `Sealing.verify` reads the claim through
  its own minter and runs `open`'s checks in the same order, so it throws
  exactly what `open` throws.
- **Compile-fail cases.** Seventeen files in `scripts/compile-fail`
  (`provenance-*.swift`) and a control that uses every public API. The draft's
  cases that name `AuthenticatedDecryption` (a moment it proved passed where
  `OwnClock` is required; a policy authenticating with it) use an evidence
  kind declared in the fixture instead: the plain build has no `StoicSealed`
  (it needs the `Crypto` trait), and the property under test is the kind
  relation, not that type. The `AppAttested` case of the same relation is
  design/29's, compiled with the `Attestation` trait.
- **The ideal scenario as a test** runs in `StoicAttestationTests`, where the
  attested body comes from design/29's stand-in.
- **Lint.** The three rules as drafted. `evidence-mint-access` also flags an
  `enum Mint` with a case (anyone who names the case can make one), and does
  not flag a caseless one (nobody can). `derivation-ignores-input` counts any
  `$n` in the closure's body as use, including a nested closure's, which is a
  known false negative.
