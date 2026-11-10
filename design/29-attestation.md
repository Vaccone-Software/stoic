# 29 · App Attest

> Built in 0.7.0, on design/28 (provenance): a verified request is a
> `Verified<AttestedRequest, AppAttested>`. The draft was reviewed and amended
> (Apple's real bytes, the facts to implement to, account binding, honesty in
> the docs); "As built" lists every departure from it. The verifier is tested
> against seven real device attestations and assertions and Apple's real root
> (Testing). Nothing here has run on a device by Stoic's hand: "What was
> verified, and what was not" says which claims rest on what.

A server cannot tell its own app from a script that calls its API. Kindora's
check-in takes `latitude` and `longitude` from whoever sends them. Its waiver
mutation takes an `acceptedTime`. A `curl` command can do both. App Attest is
Apple's answer to one part of this. It proves four things:

- a request came from an **unmodified instance of this app** (this team id and
  bundle id, built and signed by its developer);
- running on **genuine Apple hardware**;
- signed with **one particular hardware-backed key**, which lives in the Secure
  Enclave and cannot be exported;
- and the signed bytes were **not altered** on the way.

It proves nothing else. It does not prove **who the user is**: any person
holding the device signs with the same key. It does not prove that **the
content is true**: a genuine app can be handed a fake location, and a signed
check-in faithfully carries it. Every value the server verifies is a
`Verified<_, AppAttested>`. `AppAttested` is content evidence (design/28), not
principal evidence, so an attested request cannot stand in for an authenticated
person, and the compiler refuses the substitution.

Apple's framework does the cryptography and leaves the rest to the app. That
includes the key's lifecycle, a key that died with a reinstall, telling
transient errors from permanent ones, devices that cannot attest, concurrent
requests while a key is being enrolled, and the entire server side. Each is
where hand-written integrations fail:

- every request fails after a reinstall;
- the app attests again on every launch, spending Apple's rate limit and the
  device's risk metric;
- "unsupported" is skipped silently, so a modified app only has to claim it;
- the server checks the certificate chain and forgets the nonce;
- the signature covers the body and not the path;
- counters are rejected as replays when concurrent requests arrive out of order.

## The ideal scenario

> A volunteer checks in from the iPhone app. The request is signed: its method,
> host, path, query, a digest of its body, its idempotency key and a challenge
> the server issued. The first request after install enrols a key while the
> others wait for it. A key that died with a restore is replaced without the
> volunteer noticing. On a Mac or in the simulator the app says it cannot
> attest, and the server decides what that is worth. The server verifies with
> pure functions over bytes, keeps keys and counters in its own database, and
> gets a value whose type says what was proved: this request came from a
> genuine instance of the app, unaltered. It does not say who sent it, and it
> does not say the content is true.

```swift
// MARK: The app (iOS)
import StoicApple
import StoicHTTP
import StoicAttestedHTTP

let enrolment = HTTPClient(base: api, headers: auth, label: "app-attest")    // no authenticator: no cycle
let attester = AppAttester(account: user.id, secrets: KeychainSecretStore(service: "app.kindora"),
                           server: .http(enrolment))
let client = HTTPClient(base: api, headers: auth,
                        authenticator: AppAttestAuthenticator(attester, ifUnsupported: .declare))

try await client.send(.post("/v1/check-ins", json: checkIn.encoded), idempotencyKey: checkIn.key)

// MARK: The service (Swift, Linux)
import StoicAttestation

let gate = AppAttestGate(
    app: try AppID("A1B2C3D4E5.app.kindora"), environment: .production, authority: "api.kindora.app",
    challenges: try AppAttestChallenges(keys: [config.challengeKey]),
    ledger: PostgresAppAttestLedger(db), ifUnsupported: .accept)

router.post("/app-attest/challenge") { request in try gate.challenge(request.json(AppAttestChallengeRequest.self).purpose) }
router.post("/app-attest/keys") { request in
    try await gate.enrol(request.json(AppAttestEnrolment.self), account: try await sessions.verify(request))
}
router.post("/v1/check-ins") { request in
    let me = try await sessions.verify(request)                          // Verified<Someone, Session>
    do {
        switch try await gate.verify(request.signed, account: me) {
        case .attested(let attested):                                    // Verified<AttestedRequest, AppAttested>
            let body = try attested.deriving { try CheckInBody.schema.decode($0.body) }
            return try await checkIn(body, by: me)                       // the location is the genuine app's word
        case .unsupported(let claim):                                    // Claimed<AppAttestUnsupported>: anyone can say it
            return try await checkInWithoutAttestation(claim, by: me)    // the service's choice, made here
        }
    } catch let refusal as AppAttestRefusal {
        return .unauthorized(headers: gate.headers(for: refusal))        // 401, with the code and a fresh challenge
    }
}
```

## Origin

- **Apple's documentation**: "Establishing your app's integrity", "Validating
  apps that connect to your server", "Assessing fraud risk", and "Preparing to
  use the App Attest service". Also the DeviceCheck headers in the 27.2 SDKs,
  read for this draft (`DCAppAttestService.h`, `DCError.h`). The steps for
  verifying an attestation and an assertion below are Apple's, in Apple's order.
  The client rules quote the headers: record the key id right away; after
  `serverUnavailable`, retry with the same key and the same client data hash
  "to preserve the risk metric"; use one key per user account on a device; most
  app extensions cannot generate a key.
- **WebAuthn** (W3C). App Attest's attestation object, authenticator data
  layout, AAGUID and signature counter are WebAuthn's, so the parsing rules and
  the counter's meaning are too.
- **RFC 9421, HTTP Message Signatures.** The covered request components, the
  signature base, and the `Signature-Input` and `Signature` headers. A server in
  another language can build the same base with an RFC 9421 library.
  **RFC 9530** (`Content-Digest`) for the body. **RFC 8941** (Structured
  Fields) for the header syntax.
- **RFC 9449, OAuth DPoP.** A proof per request, and a server nonce that arrives
  in a `401` with `WWW-Authenticate` and a header, and is then replayed once.
  The HTTP seam below is the general form, so DPoP or SigV4 could use it too.
- **RFC 4303 §3.4.3, IPsec's anti-replay window.** It accepts each counter once,
  in any order within a window, and so tolerates reordering without accepting a
  replay.
- **Kindora.** Check-in location, identity and acceptance time are taken from
  the client (design/28, Origin). Kindora's app is Expo and React Native, and
  its server is Convex in TypeScript, so it cannot link these Swift libraries.
  It can use the wire format, which is fixed and documented here, and the
  committed test vectors, to check a TypeScript verifier against the same bytes.
- **A probe on this Mac** (macOS 27.2, Swift 6.4.2, an unsigned script):
  `DCAppAttestService.shared.isSupported` is `false`, and
  `DCDevice.current.isSupported` is `true`.

## What it proves, and what it does not

| A verified… | Proves                                                                                                                                                                            | Does not prove                                                                                                   |
| ----------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| attestation | Apple certified that this P-256 public key was generated in the Secure Enclave of a genuine Apple device, for an instance of this app id, in this environment, for this challenge | that the device or the app is still in that state later; anything about the user                                 |
| assertion   | the holder of that key signed these exact bytes, with a counter not used before                                                                                                   | who held the device; that the content is true; that the request was sent now (only that its challenge was fresh) |
| request     | the method, authority, path, query, body (by digest) and idempotency key are the ones the genuine app signed                                                                      | any header not listed; that the body's facts (a location, a moment, a date of birth) are true                    |

Further limits, stated so nobody infers more:

- **Device farms.** Real, unmodified apps on real devices driven by a script
  pass. Apple's receipt and risk metric are the only signal against that (Not
  built).
- **A compromised device.** Apple says a jailbroken device or a modified app
  fails attestation. Stoic cannot test that claim and relies on Apple for it.
- **A claim of "unsupported" is only a claim.** A modified app can say it runs
  on a Mac. The server receives `Claimed<AppAttestUnsupported>` and decides
  what an unattested client may do. Accepting every such claim makes App Attest
  advisory.

## Availability

Read from the 27.2 SDK headers. "Verified" means observed on this machine;
everything else is documentation.

| Where                                            | API in the SDK                                                                                                             | `isSupported`                                                       | Verified here                  |
| ------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- | ------------------------------ |
| iPhone, iPad                                     | iOS 14                                                                                                                     | true on supported hardware (documentation)                          | no: no device                  |
| iOS Simulator                                    | compiles                                                                                                                   | false (documentation)                                               | no: not run                    |
| macOS app                                        | macOS 11                                                                                                                   | false: the header says so for "an app running on a Mac device"      | **yes**: `false` on macOS 27.2 |
| Mac Catalyst; an iOS app on an Apple silicon Mac | compiles                                                                                                                   | false (the same header note names both)                             | no                             |
| tvOS                                             | tvOS 15                                                                                                                    | not documented                                                      | no                             |
| watchOS, and watchOS app extensions              | watchOS 9                                                                                                                  | not documented beyond "extensions in watchOS 9 or later support it" | no                             |
| visionOS                                         | not named in the header; available by inheriting the iOS annotation; `DCAppAttestService` is exported in the `xros` `.tbd` | not documented                                                      | no: SDK only                   |
| app extensions other than watchOS                | compiles                                                                                                                   | may be true; `generateKey` fails regardless (header)                | no                             |

The macOS header contradicts itself. The class is available since macOS 11, is
documented as unsupported "on a Mac device", and has a `DCError.invalidKey` case
for "cannot enforce the key access control policy on macOS". Stoic therefore
decides support from `isSupported` and the environment together (Semantics,
Unsupported) and makes no assumption per platform. The platform floor (27)
makes every symbol available at compile time. The library builds everywhere, and
the platforms that cannot attest answer `.unsupported`.

## Rules

1. **One key per account per install. Never a key per request, and never
   attest a key twice.** Attestation goes through Apple's service, is rate
   limited, and feeds the device's risk metric. An assertion is local.
2. **Unsupported is an answer the app gives.** The authenticator has no default
   for `ifUnsupported:`. It either declares the claim to the server or fails the
   request, and it never sends the request as if attestation did not exist.
3. **The server never reads the client's clock.** Freshness comes from
   challenges the server issued and checks against its own clock.
4. **The signature covers a fixed statement, and the server rebuilds it from
   what it received.** Nothing the server acts on is taken from the signature's
   own parameters except the key id and the challenge, and both are then checked.
5. **Refusals are told apart.** A stale challenge, an unknown key, a revoked
   key, a replay, an invalid signature and a missing one each have their own
   code, and the client does something different for each.
6. **A server checks attestation before it acts.** A `401` therefore means
   nothing happened, and the client's single replay is safe for any method, as
   design/19's reauthentication replay is.

## Building it

| Library             | Where                                             | Depends on                                                                             | Trait                                |
| ------------------- | ------------------------------------------------- | -------------------------------------------------------------------------------------- | ------------------------------------ |
| `StoicApple`        | Apple platforms (empty parts elsewhere, as today) | `Stoic`, `StoicFoundation`; DeviceCheck and CryptoKit, both system frameworks          | none                                 |
| `StoicHTTP`         | portable                                          | as today; gains the authenticator seam                                                 | none                                 |
| `StoicAttestedHTTP` | Apple platforms                                   | `StoicApple`, `StoicHTTP`, `Stoic`; CryptoKit                                          | none                                 |
| `StoicAttestation`  | portable (the server's)                           | `Stoic`; swift-crypto's `Crypto`, swift-certificates' `X509`, swift-asn1's `SwiftASN1` | **`Attestation`** (enables `Crypto`) |

- **The client fetches nothing.** `DCAppAttestService` and CryptoKit's `SHA256`
  ship with the OS. `StoicAttestedHTTP` is the one place `StoicApple` and
  `StoicHTTP` meet, for the same reason `StoicSealedKeychain` is where
  `StoicSealed` and `StoicApple` meet. An app that adopts either library alone
  builds neither the other nor what it brings, and the layering
  ("Apple libraries sit on the core and the Foundation table") stays as it is.
- **The server verifier sits behind a new trait.** `.trait(name: "Attestation",
description: "Build StoicAttestation, the App Attest verifier. Pulls in
swift-certificates, and swift-crypto through Crypto, which are fetched only
when this trait is enabled.", enabledTraits: ["Crypto"])`. Enabling `Crypto`
  already fetches swift-crypto and swift-asn1, because swift-crypto declares
  swift-asn1 (this checkout resolves swift-asn1 1.7.4 beside swift-crypto
  5.1.1). `Attestation` adds one new package, swift-certificates. A consumer
  that does not enable it fetches nothing new. `scripts/adoption.sh` checks this
  as it does for `Crypto`. Without the trait the module is empty, as
  `StoicSealed` is.
- **Why swift-certificates, and not chain validation by hand.** X.509 path
  validation is where verifier bugs live: name chaining, validity at a moment,
  CA and path-length constraints, signature algorithms, and critical extensions.
  Getting any of these wrong turns "a chain to Apple's root" into "a chain to
  anything". swift-certificates is maintained by Apple's Swift server team,
  validates by policy (`Verifier`, `RFC5280Policy`), and can also _build_
  certificates, which the stand-in attester needs (Testing). Hand-writing a
  three-certificate verifier on swift-asn1 would fetch nothing new and would
  break design/24's rule 1 in spirit: no home-made cryptography.
- **What is hand-written, and why that is safe.**

  - A **CBOR reader** for a strict subset of RFC 8949: definite-length unsigned
    integers, byte strings, text strings, arrays and maps (major types 0, 2, 3,
    4, 5). It refuses everything else: negative integers, tags, floats and
    simple values, indefinite lengths, reserved additional information, map keys
    that are not text, duplicate keys, nesting deeper than 4, more than 16 items
    in a container, input over 64 KiB, and trailing bytes. It is total: every
    length is checked against the bytes remaining before anything is sliced, all
    arithmetic is checked, and a malformed input is
    `AttestationFailure.malformed` or `AssertionFailure.malformed`, never a trap.
  - A **Structured Fields subset** (RFC 8941) for the four headers below: a
    dictionary whose members are an inner list of strings with string
    parameters, or a byte sequence; an item that is a byte sequence with an
    integer parameter; a token with a token parameter. Strict and total, under
    the same limits, refusing headers over 16 KiB.
  - The **authenticator data** layout (fixed offsets) and the **signature
    base** (string assembly).

  None of these decides trust. They only locate bytes, and every byte that
  matters is then authenticated by something that is not hand-written. The
  certificates are checked by swift-certificates against a pinned root. The
  attestation's authenticator data is bound by the nonce in the certified
  credential certificate. An assertion's authenticator data and the request
  statement are covered by an ECDSA signature that swift-crypto checks. A
  parsing bug can therefore cause a refusal, but not an acceptance that
  verification would refuse. The one way a parser could cause one is ambiguity:
  two readings of the same bytes. Duplicate keys, trailing bytes and alternative
  forms are refused for that reason. Property tests feed every parser random
  bytes and mutated valid inputs (Testing).

**Verified at implementation.** swift-certificates admits swift-crypto 5 from
1.21.0 (`"3.12.3"..<"6.0.0"`; 1.20 stopped below 5). Stoic depends on it
`from: "1.21.0"`, and this checkout resolves swift-certificates 1.21.1 beside
swift-crypto 5.1.1 and swift-asn1 1.7.4.

## API

```swift
// MARK: StoicApple: the key, on the device

/// The App Attest key of one account on this install: generated, attested and
/// enrolled once, kept in a `SecretStore`, replaced when it dies.
public actor AppAttester {
    public init(account: String, secrets: any SecretStore, server: any AppAttestServer,
                service: any AppAttestService = SystemAppAttestService(), policy: AppAttestPolicy = .standard)
    /// Decided once, at init, from the environment and the service. Never throws.
    public nonisolated let availability: AppAttestAvailability
    public var state: AppAttestState { get }
    /// The enrolled key, enrolling one if needed: one enrolment, however many callers.
    public func enrolledKey() async throws(AppAttestError) -> AppAttestKeyID
    /// An assertion object over a 32-byte client data hash, signed by `key`.
    public func assertion(over clientDataHash: [UInt8], with key: AppAttestKeyID) async throws(AppAttestError) -> [UInt8]
    /// The server does not know `key`, or the device refused it: forget it, so the next call enrols another.
    public func discard(_ key: AppAttestKeyID, because reason: String) async throws(AppAttestError)
    /// The server revoked `key`: forget it, and enrol nothing for `refusedRetryAfter`.
    public func revoked(_ key: AppAttestKeyID) async throws(AppAttestError)
    /// A request challenge: the one the enrolment returned while fresh, else the server's.
    public func requestChallenge() async throws(AppAttestError) -> AppAttestChallenge
}

public enum AppAttestAvailability: Sendable, Hashable { case supported, unsupported(AppAttestUnsupported) }
public enum AppAttestUnsupported: String, Sendable, Hashable, Codable { case mac, simulator, appExtension = "app-extension", device }
public enum AppAttestState: Sendable, Hashable {
    case unsupported(AppAttestUnsupported), notEnrolled, enrolling, enrolled(AppAttestKeyID), failed(AppAttestError)
}
/// The key id as `generateKey` returns it: base64 of the SHA-256 of the public key. Not secret; links one install.
public struct AppAttestKeyID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let base64: String
    public var description: String { get }                    // the first 6 characters and "…"
}
public struct AppAttestPolicy: Sendable, Hashable {
    public var enrolmentTimeout: Duration                     // 60 s: one enrolment, start to finish
    public var unavailableBackoff: BoundedSchedule            // exponential from 2 s, capped at 60 s, within the timeout
    public var systemFailureAttempts: Int                     // 3
    public var refusedRetryAfter: Duration                    // 1 h: after a refused enrolment or a refused fresh key
    public var keysPerEnrolment: Int                          // 2: a fresh key after a spent one, never a third
    public static let standard: AppAttestPolicy
}
public enum AppAttestError: Error, Sendable, Hashable, Retryable {
    case unsupported(AppAttestUnsupported)   // .stop
    case serviceUnavailable                  // Apple's service could not be reached while attesting: .retry
    case systemFailure                       // DCError.unknownSystemFailure, after its attempts: .retry
    case keyInvalidated                      // the device's key is gone; it was discarded: enrol again, sign again
    case keyRefused                          // a fresh key was refused too: .stop until refusedRetryAfter
    case invalidInput                        // DCError.invalidInput: Stoic's bug, reported at error level: .stop
    case enrolmentRefused(code: String)      // the app's server refused the attestation: .stop
    case serverUnavailable(RetryDecision)    // the app's server could not be asked: its own classification
    case keychain(SecretStoreError)          // the key's record could not be read or kept: its own classification
    case timedOut                            // the enrolment outlasted its timeout, or a waiter its deadline: .retry
    case cancelled                           // the caller was cancelled: `isCancellation` is true
}

/// DCAppAttestService's shape: the seam tests replace.
public protocol AppAttestService: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}
public struct SystemAppAttestService: AppAttestService { public init() }       // DCAppAttestService.shared
/// Keys, attestations, assertions and `DCError`s from a script; delays on the ambient clock; every call recorded.
public final class ScriptedAppAttestService: AppAttestService { … }

/// The app's server, as the attester needs it: a challenge, and an enrolment.
public protocol AppAttestServer: Sendable {
    func challenge(for purpose: AppAttestChallengePurpose) async throws(AppAttestServerError) -> AppAttestChallenge
    /// Returns the first request challenge, if the server gives one.
    func enrol(_ key: AppAttestKeyID, attestation: [UInt8], challenge: AppAttestChallenge)
        async throws(AppAttestServerError) -> AppAttestChallenge?
}
public enum AppAttestChallengePurpose: String, Sendable, Hashable, Codable { case enrolment, requests }
public struct AppAttestChallenge: Sendable, Hashable, Codable { public let bytes: [UInt8]; public let lifetime: Duration }
public enum AppAttestServerError: Error, Sendable, Hashable, Retryable {
    case unreachable(RetryDecision, neverReachedBackend: Bool)
    case refused(code: String)
}

// MARK: StoicHTTP: the seam (portable; nothing about App Attest)

/// Adds credentials that depend on the request itself to every attempt: a
/// signature, a proof of possession. Runs only for requests to the base URL's origin.
public protocol HTTPAuthenticator: Sendable {
    /// Before the host's policies, once per hop: may wait (an enrolment). Holds no slot. Default: nothing.
    func prepare(_ request: HTTPRequest) async throws(HTTPAuthenticationError)
    /// At the start of every attempt, retries included: the headers for this attempt. Must not send through this client.
    func authenticate(_ request: HTTPRequest) async throws(HTTPAuthenticationError) -> HTTPHeaders
    /// Every response to an authenticated attempt, before retry and reauthentication see it. Default: `.accept`.
    func received(_ response: HTTPResponse, to request: HTTPRequest) async -> HTTPAuthenticatorVerdict
}
public enum HTTPAuthenticatorVerdict: Sendable, Hashable {
    case accept                                    // as if there were no authenticator
    case replay                                    // prepare, authenticate and send once more (once per hop)
    case refuse(HTTPAuthenticationError)           // the call fails with this; reauthentication does not run
}
public struct HTTPAuthenticationError: Error, Sendable, Hashable, Retryable, CustomStringConvertible {
    public let scheme: String                      // "AppAttest"
    public let code: String                        // "unsupported", "revoked", "invalid", "timed_out", …
    public let retryDecision: RetryDecision
    public init(scheme: String, code: String, retryDecision: RetryDecision)
}
extension HTTPClient {
    /// An overload: the existing initialiser is unchanged.
    public convenience init(base: URL, policy: HTTPPolicy = .standard, transport: any HTTPTransport = URLSessionTransport(),
                            headers: HTTPHeaders = [:], label: String = "http",
                            reauthenticate: (@Sendable () async throws -> HTTPHeaders)? = nil,
                            authenticator: any HTTPAuthenticator)
}
extension HTTPError { case authenticationFailed(HTTPAuthenticationError, attempts: Int) }   // a new case: a listed break
extension HTTPOverrides { public var authenticate: Bool }                                   // default true: false skips the authenticator

// MARK: StoicAttestedHTTP: App Attest as an HTTP authenticator

public final class AppAttestAuthenticator: HTTPAuthenticator {
    /// `ifUnsupported` has no default: what an app that cannot attest does is the app's decision.
    public init(_ attester: AppAttester, signing: AppAttestSigning = .unsafeMethods, ifUnsupported: AppAttestFallback)
}
public enum AppAttestSigning: Sendable { case unsafeMethods, every, matching(@Sendable (HTTPRequest) -> Bool) }
public enum AppAttestFallback: Sendable, Hashable {
    case declare                                   // send `App-Attest: unsupported;reason=…`: the server decides
    case fail                                      // send nothing: `HTTPError.authenticationFailed(code: "unsupported")`
}
public struct HTTPAppAttestServer: AppAttestServer { … }
extension AppAttestServer where Self == HTTPAppAttestServer {
    /// The wire protocol below, over `client`, which must not be the client the authenticator signs for.
    public static func http(_ client: HTTPClient, challengePath: String = "/app-attest/challenge",
                            keysPath: String = "/app-attest/keys") -> HTTPAppAttestServer
}
/// The statement and headers of format v1, exposed for tests and the vectors.
public enum AppAttestRequestFormat {
    public static func signatureBase(method: String, authority: String, path: String, query: String,
                                     contentDigest: String, idempotencyKey: String?, keyID: String, nonce: [UInt8]) -> String
}

// MARK: StoicAttestation: the server's verifier (trait Attestation; portable)

public struct AppID: Sendable, Hashable, Codable, CustomStringConvertible {
    public init(_ text: String) throws(AppIDError)           // "TEAMID.bundle.id": a 10-character team id, a dot, a bundle id
    public let teamID: String; public let bundleID: String
    public var rpIDHash: [UInt8] { get }                      // SHA-256 of the UTF-8 text
}
public enum AppAttestEnvironment: String, Sendable, Hashable, Codable { case development, production }
public struct AppAttestRoot: Sendable, Hashable {
    public static let apple: AppAttestRoot                    // Apple App Attestation Root CA, DER embedded, fingerprint pinned
    public init(der: [UInt8]) throws(AttestationFailure)      // a test root
    public let fingerprint: [UInt8]                           // SHA-256 of the DER
}

/// What the server keeps from an enrolment.
public struct AttestedKey: Sendable, Hashable, Codable {
    public let id: [UInt8]                                    // 32 bytes: SHA-256 of `publicKey`
    public let publicKey: [UInt8]                             // 65 bytes: X9.63 uncompressed P-256 point
    public let app: AppID
    public let environment: AppAttestEnvironment
    public let receipt: [UInt8]                               // kept for the risk metric (Not built)
}
public struct KeyAttested: Evidence, Hashable {             // Mint fileprivate to the verifier
    public static let proves = "Apple certified this key for this app id and environment, for this challenge"
    public let root: [UInt8]; public let verifiedAt: Moment
}
public struct AppAttested: ContentEvidence, Hashable {      // Mint fileprivate to the verifier; not PrincipalEvidence
    public static let proves = "signed by an App Attest key Apple certified for an unmodified instance of this app on genuine hardware; unaltered; its counter is new"
    public let key: [UInt8]; public let app: AppID; public let environment: AppAttestEnvironment
    public let counter: UInt32; public let account: String?
}

/// Per key, in the server's database.
public struct AppAttestKeyRecord: Sendable, Hashable, Codable {
    public let key: AttestedKey
    public let account: String?                               // the app's account the key was enrolled for
    public let enrolledAt: Moment
    public let attestationDigest: [UInt8]                     // SHA-256 of the attestation object: a repeated enrolment is recognised
    public let counter: AssertionCounter
    public let status: Status                                 // .active, .revoked(reason: String, at: Moment)
    public let revision: UInt64                               // 1 at enrolment, +1 per accepted assertion: compare-and-set
    public func revoked(because: String, at: Moment) -> AppAttestKeyRecord
}
public struct AssertionCounter: Sendable, Hashable, Codable {
    public let highest: UInt32                                // the highest counter accepted (0 after enrolment)
    public let seen: UInt64                                   // bit i: `highest - i` was accepted
    public func accepting(_ counter: UInt32, reorderWindow: Int) -> Result<AssertionCounter, AssertionFailure>
}

public enum AppAttest {
    /// Apple's attestation checks, in Apple's order. Pure.
    public static func verifyAttestation(_ object: [UInt8], keyID: String, challenge: [UInt8], app: AppID,
        environment: AppAttestEnvironment, root: AppAttestRoot = .apple, at now: Moment)
        async throws(AttestationFailure) -> Verified<AttestedKey, KeyAttested>   // async: swift-certificates' validation is
    /// Apple's assertion checks, and the counter window. Pure: the caller commits `record` over the old revision.
    public static func verifyAssertion(_ assertion: [UInt8], over clientData: [UInt8], record: AppAttestKeyRecord,
        reorderWindow: Int = 32) throws(AssertionFailure) -> AcceptedAssertion
    /// The key id and challenge a request names, to look them up. Parses; verifies nothing.
    public static func signature(of request: SignedRequest) throws(AssertionFailure) -> RequestSignature?
    /// A request: the components, the body's digest, the assertion, the counter. Pure.
    public static func verifyRequest(_ request: SignedRequest, authority: String, record: AppAttestKeyRecord,
        reorderWindow: Int = 32) throws(AssertionFailure) -> AcceptedRequest
}
public struct SignedRequest: Sendable, Hashable {             // what the server received, from any framework
    public init(method: String, path: String, query: String, headers: [(name: String, value: String)], body: [UInt8])
}
public struct RequestSignature: Sendable, Hashable { public let keyID: [UInt8]; public let nonce: [UInt8]; public let unsupported: AppAttestUnsupported? }
public struct AttestedRequest: Sendable, Hashable {
    public let method: String; public let authority: String; public let path: String; public let query: String
    public let idempotencyKey: String?; public let body: [UInt8]
}
public struct AcceptedAssertion: Sendable { public let verified: Verified<[UInt8], AppAttested>; public let record: AppAttestKeyRecord }
public struct AcceptedRequest: Sendable { public let verified: Verified<AttestedRequest, AppAttested>; public let record: AppAttestKeyRecord }

/// Challenges the server can check without storing: MAC'd, dated by its own clock.
public struct AppAttestChallenges: Sendable {
    public init(keys: [Secret<[UInt8]>], enrolmentLifetime: Duration = .seconds(600), requestLifetime: Duration = .seconds(300),
                maxSkew: Duration = .seconds(30)) throws(ChallengeRefusal)   // each key 32 bytes; the first issues, all check
    public func issue(_ purpose: AppAttestChallengePurpose, at now: Moment = .now) -> AppAttestChallenge
    public func check(_ bytes: [UInt8], for purpose: AppAttestChallengePurpose, at now: Moment = .now)
        throws(ChallengeRefusal) -> CheckedChallenge          // id (for single use), issued, expires
}
/// The server's storage of keys and spent enrolment challenges: the app's, in its database.
public protocol AppAttestLedger: Sendable {
    func key(_ id: [UInt8]) async throws -> AppAttestKeyRecord?
    func insert(_ record: AppAttestKeyRecord) async throws -> Bool                      // false: the id exists
    func commit(_ record: AppAttestKeyRecord, over revision: UInt64) async throws -> Bool   // compare-and-set
    func remove(_ id: [UInt8]) async throws
    func spend(challenge id: [UInt8], until expiry: Moment) async throws -> Bool       // false: already spent
}
public actor InMemoryAppAttestLedger: AppAttestLedger { … }   // tests
/// The reference composition: challenges, enrolment, request verification, the ledger, events.
public struct AppAttestGate: Sendable {
    public init(app: AppID, environment: AppAttestEnvironment, authority: String, root: AppAttestRoot = .apple,
                challenges: AppAttestChallenges, ledger: any AppAttestLedger, reorderWindow: Int = 32,
                ifUnsupported: UnsupportedClients)                 // no default: .accept or .refuse
    public func challenge(_ purpose: AppAttestChallengePurpose) -> AppAttestChallenge
    public func enrol(_ enrolment: AppAttestEnrolment, account: String?) async throws(AppAttestRefusal) -> AppAttestChallenge
    public func verify(_ request: SignedRequest, account: String?) async throws(AppAttestRefusal) -> GateOutcome
    public func headers(for refusal: AppAttestRefusal) -> [(name: String, value: String)]
}
public enum GateOutcome: Sendable { case attested(Verified<AttestedRequest, AppAttested>, freshChallenge: AppAttestChallenge?)
                                    case unsupported(Claimed<AppAttestUnsupported>) }
public enum UnsupportedClients: Sendable, Hashable { case accept, refuse }
public struct AppAttestRefusal: Error, Sendable, Hashable, Retryable {
    public let code: String; public let cause: String; public let challenge: AppAttestChallenge?
    public var status: Int { get }                            // 422 enrolment, 401 request, 503 `unavailable`
}
public enum AttestationFailure: Error, Sendable, Hashable, Retryable { … }     // below; all .stop
public enum AssertionFailure: Error, Sendable, Hashable, Retryable { … }       // below; all .stop
public enum ChallengeRefusal: Error, Sendable, Hashable, Retryable { case malformed, forged, wrongPurpose, expired, fromTheFuture, spent, badKey }

/// A software attester for tests: real P-256 keys, a real chain to a test root.
public final class AppAttestStandIn: Sendable { … }   // Testing
```

`AppAttestServerError`, the gate's codes and the wire JSON are generic enough
that `AppAttestServer` does not depend on HTTP. `StoicAttestation`'s
`AppAttestChallengePurpose` and `AppAttestChallenge` are the same names and
JSON as `StoicApple`'s, declared twice because neither library can see the
other. A module that imports both, as a test target does, writes
`StoicApple.AppAttestChallenge` or `StoicAttestation.AppAttestChallenge`.

## Semantics

### The key, on the device

The attester keeps one record in the `SecretStore`, under
`stoic.app-attest.<account>`: JSON, `{"v":1,"key":…,"phase":…,"challenge":…,"challengeAt":…,"attestation":…}`.
Apple's advice is to record the key id the moment it exists. The key is
unusable without its id, and the id is useless without the record of how far
enrolment got. Phases:

| Phase       | Held                                        | Next                                                                                |
| ----------- | ------------------------------------------- | ----------------------------------------------------------------------------------- |
| (none)      | nothing                                     | `generateKey`, and the id is written as `generated` before anything else            |
| `generated` | the key id                                  | an enrolment challenge from the server, written as `attesting` with when it arrived |
| `attesting` | key id, challenge, its arrival (a `Moment`) | `attestKey(id, SHA-256(challenge))`; the attestation is written as `attested`       |
| `attested`  | key id, challenge, attestation object       | the enrolment `POST`; on success written as `enrolled`                              |
| `enrolled`  | the key id                                  | assertions                                                                          |
| `refused`   | the code, and until when (a `Moment`)       | nothing until then: an enrolment refused, a fresh key refused, or a key revoked     |

**Each step is written before the next begins.** A process that dies resumes
from the last phase written:

- after `generateKey`, before its id is written: the key is orphaned in the
  Secure Enclave, unreachable and harmless, and the next run generates another;
- after `attestKey` succeeded, before the attestation is written: a second
  `attestKey` on that key fails `invalidKey` ("already attested", header), so
  the key is discarded and enrolment starts again from a new one, costing one
  extra attestation;
- after the enrolment `POST`, before `enrolled` is written: the `POST` is sent
  again with the attestation that was kept. The server recognises it as the same
  enrolment (below).

**The store's own rules hold** (design/21). `get` returning `nil` is the only
"no key", and a locked Keychain is `.keychain(.locked)`, never a reason to
generate a key. `KeychainSecretStore`'s default,
`afterFirstUnlockThisDeviceOnly`, keeps the record out of backups, so a restore
to another device starts with no record and enrols cleanly. A store that does
let the record travel produces a record whose key does not exist on the new
device. That key fails `invalidKey` and is replaced (below), so it costs one
extra attestation and nothing else.

**One key per account** (Apple: "Create a unique key for each user account on a
device"). `account` is a label the app chooses, not a secret. Switching account
uses another record and another key.

### Enrolment

`enrolledKey()` returns the enrolled key at once. Otherwise it joins the
enrolment in flight or starts one. **The enrolment is the attester's own work**
(`Task.owned`, as `XPCPeer`'s handshake is): it is bounded by
`enrolmentTimeout`, not by the deadline of whoever started it, and it goes on
when a waiter leaves. Each waiter is bounded by its own deadline and
cancellation, and leaves with `.timedOut` or `.cancelled`. A hundred requests
during an enrolment are one key, one attestation and one `POST`.

The steps, from the phase on record:

1. **A challenge** from `server.challenge(for: .enrolment)`. The client data
   hash is `SHA-256(challenge.bytes)`.
2. **`attestKey(key, hash)`.**
   - `serverUnavailable`: retry with the **same key and the same hash**, on
     `unavailableBackoff`, while the enrolment's timeout and the challenge's
     lifetime both last. A challenge past its lifetime, measured by the wall
     clock from the arrival on record, is replaced, and the key kept. A wrong
     clock costs at worst a server refusal of an expired challenge.
   - `unknownSystemFailure`: retried up to `systemFailureAttempts`.
   - `invalidKey`: the key is spent (already attested, or rejected). It is
     discarded, and the steps start again with a new key, at most
     `keysPerEnrolment` keys per enrolment. A second fresh key that fails the
     same way is `.keyRefused`: reported at error level, and refused until
     `refusedRetryAfter`.
   - `featureUnsupported`: `.unsupported(.device)`, recorded in the state, and
     never retried.
   - `invalidInput`: `.invalidInput`, a defect in Stoic, reported at error level.
3. **`server.enrol(key, attestation, challenge)`**, retried as its error
   classifies (the HTTP server below sends it keyed, so the client retries it).
   A refusal:
   - `challenge_expired`, `challenge_used`: the attestation is bound to that
     challenge, and the key cannot be attested again. The key is discarded, and
     the steps start again from a new key.
   - any other code: `.enrolmentRefused(code)`. The key is discarded and the
     state is `failed` until `refusedRetryAfter`.
4. **Enrolled.** The first request challenge, if the server returned one, is
   held in memory for the authenticator.

A failed enrolment leaves the phase on record where it stopped, except where a
step above discards the key. The next `enrolledKey()` after any wait
(`refusedRetryAfter`, or none for a transient failure) resumes from that phase.
Apple's rate limit and risk metric are therefore spent once per key, however
many times the network fails.

### Assertions

`assertion(over:with:)` calls `generateAssertion(key, hash)`. The key must be
the one currently enrolled. A key that was discarded meanwhile fails
`.keyInvalidated` without asking the device.

- `invalidKey`: **the device's key is gone.** The documented causes are a
  reinstall, a restore and a migration. The attester discards it if it is still
  the current key, so two requests that find the same dead key cause one
  re-enrolment. It reports `attest.key_invalidated` and throws
  `.keyInvalidated`. The authenticator then enrols, rebuilds the statement
  (which names the key) and asserts once more. A second `.keyInvalidated` for
  the same request is final.
- `unknownSystemFailure`: retried up to `systemFailureAttempts`, then
  `.systemFailure`.
- Assertions run concurrently. `generateAssertion` is local. Apple documents no
  serialisation, and the counter each one takes is whatever the Secure Enclave
  assigns, so assertions can complete and arrive in any order. The server's
  counter window allows for that.

### `DCError`, classified

| `DCError` (code)           | From                | Means (header)                                   | Stoic                                                                                                                             |
| -------------------------- | ------------------- | ------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------- |
| `unknownSystemFailure` (0) | any                 | "a failure has occurred"                         | retried up to 3 times, then `.systemFailure`, `.retry`. Not proved transient: the documentation's wording, unverified on a device |
| `featureUnsupported` (1)   | any                 | unavailable on this device                       | `.unsupported(.device)`, `.stop`                                                                                                  |
| `invalidInput` (2)         | any                 | data not formatted correctly                     | `.invalidInput`: Stoic's defect, error level, `.stop`                                                                             |
| `invalidKey` (3)           | `attestKey`         | already attested; or the service rejects the key | the key is discarded; a new one, at most `keysPerEnrolment`; then `.keyRefused`                                                   |
| `invalidKey` (3)           | `generateAssertion` | unattested key; key gone (reinstall, restore)    | the key is discarded; `.keyInvalidated`; enrol again and sign again, once                                                         |
| `serverUnavailable` (4)    | `attestKey`         | could not reach the App Attest service           | retry with the same key and hash (above); after the timeout `.serviceUnavailable`, `.retry`                                       |
| another domain             | any                 | not documented                                   | Foundation's table if it is a `URLError` or `POSIXError` (design/05), otherwise `.systemFailure`                                  |

`neverReachedBackend` is true for every error from `generateKey` and
`generateAssertion`, which are local and send nothing to the app's server. It
is false for `attestKey`, because whether Apple's service counted an attempt is
unknown.

### Unsupported

`availability` is decided once:

- `#if targetEnvironment(simulator)`: `.simulator`.
- macOS, Mac Catalyst, or `ProcessInfo.isiOSAppOnMac`: `.mac`, unless
  `isSupported` is true, in which case support is tried.
- An app extension, recognised by a main bundle path ending in `.appex`, on any
  platform but watchOS: `.appExtension`, whatever `isSupported` says, because
  the header says `generateKey` fails there.
- Otherwise `isSupported == false`: `.device`.

`featureUnsupported` later, from `generateKey`, also moves the state to
`.unsupported(.device)`. `attest.unsupported` is reported once per attester.
Nothing is generated, attested or stored on an unsupported device.

The authenticator's `ifUnsupported:` decides what a request does then, and has no
default:

- `.declare` sends the request with `App-Attest: unsupported;reason=mac` (or
  `simulator`, `app-extension`, `device`) and no signature. The server sees a
  claim and decides.
- `.fail` sends nothing. The call fails
  `HTTPError.authenticationFailed(code: "unsupported")`, `.stop`, with
  `neverReachedBackend` true.

### Signing an HTTP request: format v1

**The statement** is an RFC 9421 signature base over a fixed list of
components, with label `attest`:

- covered components, in this order: `"@method"`, `"@authority"`, `"@path"`,
  `"@query"`, `"content-digest"`, then `"idempotency-key"` when the request
  carries an `Idempotency-Key`;
- signature parameters, in this order: `keyid` (the key id exactly as
  `generateKey` returned it: standard base64, with padding, of the 32-byte
  SHA-256 of the public key), `nonce` (the request challenge, standard base64
  with padding), `alg="apple-app-attest"`.

Component values:

| Component         | Value                                                                                                                                                                                                             |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `@method`         | the method as sent, upper case                                                                                                                                                                                    |
| `@authority`      | the URL's host in lower case, with `:port` only when it is not the scheme's default. **The server uses its configured `authority`**, never the `Host` it received, so a proxy that rewrites `Host` breaks nothing |
| `@path`           | the absolute path exactly as sent, percent-encoded (`URLComponents.percentEncodedPath` of the final URL); `/` when empty                                                                                          |
| `@query`          | `?` and the query exactly as sent, percent-encoded; `?` alone when there is none (RFC 9421 §2.2.7)                                                                                                                |
| `content-digest`  | `sha-256=:<base64 of SHA-256 of the body as sent>:`; for no body, the digest of zero bytes, `sha-256=:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=:`                                                              |
| `idempotency-key` | the header's value                                                                                                                                                                                                |

The base is one line per component, `"<component>": <value>` and a line feed
(0x0A), then `"@signature-params": <the parameters>` with no line feed after
it, in UTF-8. Every value is visible ASCII. A component that is not (which
`StoicHTTP` cannot produce) fails the request
`authenticationFailed(code: "unsignable")` before it is sent. **The client data
hash is `SHA-256(base)`.** The signed request carries:

```http
Content-Digest: sha-256=:<base64>:
Signature-Input: attest=("@method" "@authority" "@path" "@query" "content-digest" "idempotency-key");keyid="<id>";nonce="<challenge>";alg="apple-app-attest"
Signature: attest=:<base64 of the assertion object>:
```

The authenticator sets `Content-Digest` itself, replacing any the request had.
A request that already has a `Signature` or `Signature-Input` header fails
`authenticationFailed(code: "header_conflict")`, because two signers would
overwrite each other.

**A worked example**, also committed as the first vector. A `POST` to
`https://api.example.com/v1/check-ins?event=e42` with body
`{"event":"e42","at":"site"}`, key id
`AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=`, and the 42-byte challenge
`AQIAAAGabxssAAABAgMEBQYHCAkKCwwNDg+goaKjpKWmp6ipqqusra6v`. The base is 457
bytes:

```text
"@method": POST
"@authority": api.example.com
"@path": /v1/check-ins
"@query": ?event=e42
"content-digest": sha-256=:TFIG1rH3ac1z4inoc/WSdJvUoBvcPaNKY+HcrXjxBAw=:
"idempotency-key": 3f2a9c1e-7b40-4d1a-9e55-0c6b2d8f1a73
"@signature-params": ("@method" "@authority" "@path" "@query" "content-digest" "idempotency-key");keyid="AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=";nonce="AQIAAAGabxssAAABAgMEBQYHCAkKCwwNDg+goaKjpKWmp6ipqqusra6v";alg="apple-app-attest"
```

Its client data hash is `Slmfi7Tpym02yJb133bgVo8qJ4JcehJjSYX0vDUVz1U=` (base64).
I computed it for this draft with `openssl dgst -sha256`. The implementation
must reproduce it, and it is pinned in a test.

**Not covered, deliberately**: every other header, among them `Authorization`.
The bearer token is checked by the service's session verifier and may be renewed
by design/19's reauthentication between a signature and its replay. The scheme,
too, is left out: `https` is enforced by the client (no redirect to `http`) and
by the server's deployment.

### Where it hooks into the client

The sending path is `run` (redirect hops), then `exchange` (the reauthentication
replay), `execute` (the host's policies) and `attempt` (one request). The seam
adds three calls:

- **`prepare`**, once per hop, in `exchange` before `execute`: before the host's
  retry, breaker, rate limit and bulkhead. A wait for an enrolment therefore
  holds none of the host's eight slots, and the enrolment's own requests,
  through their own client, are never queued behind the requests waiting for
  them. The caller's deadline bounds it. A throw fails the call
  `.authenticationFailed(error, attempts: 0)`, with `neverReachedBackend` true.
- **`authenticate`**, at the start of every attempt in `attempt`, before the
  attempt timeout starts. Its headers are added to that attempt's request only.
  **Every retry is signed afresh**: a new assertion and a new counter, with the
  same idempotency key, because the request is the same. The method must not
  send through this client. The App Attest authenticator only signs, and gets
  challenges and keys from the `AppAttester`, whose server is another client.
- **`received`**, for every response to an authenticated attempt, success
  included, before retry classification and the reauthentication hook see it.
  `.replay` makes the client call `prepare` and `authenticate` again and send
  once more. That counts as an attempt, does not use the retry schedule, and
  happens at most once per hop. A second refusal is the answer. `.refuse(e)`
  fails the call `.authenticationFailed(e, attempts:)`, and the
  reauthentication hook does not run for that response. `.accept` leaves
  everything as today, including a `401` without `AppAttest` reaching the
  reauthentication hook.

Which requests are authenticated:

- **Only requests that carry the client's headers**: the base URL's origin,
  while the redirect chain has not left it (design/19). A redirect to another
  origin is sent with no `Signature`, `Signature-Input`, `Content-Digest` or
  `App-Attest`, and, as today, no idempotency key or credential.
- **A same-origin redirect is signed afresh** for its own path and method. A
  `303` becomes a `GET` without a body, so its digest is the empty body's.
- **`AppAttestSigning`**: `.unsafeMethods` by default (`POST`, `PUT`, `PATCH`,
  `DELETE`), `.every`, or a predicate. `HTTPOverrides.authenticate = false`
  skips the authenticator for one call.
- **Coalesced `GET`s** share one flight, so one request is signed, when `GET`s
  are signed at all. **A streamed request** is signed as a buffered one is: the
  request body is in memory (`HTTPRequest.body`), and only the response
  streams. **Inside a `perform` attempt** (design/22), the one attempt is signed.

`HTTPError.authenticationFailed` takes its `retryDecision` from the
authenticator's error. It claims `neverReachedBackend` when it was thrown
before the call's first request was sent, by design/19's rule for a call's
first request. A breaker never counts it, nor the `401` behind a refusal (a 4xx).

### The wire protocol with the app's server

Everything a server in another language must implement. All JSON is UTF-8, and
all byte strings are standard base64 with padding.

| Exchange                                                          | Request                                                | Success                                                                | Refusal                                                                                                     |
| ----------------------------------------------------------------- | ------------------------------------------------------ | ---------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `POST <challengePath>`                                            | `{"purpose": "enrolment" \| "requests"}`               | `200 {"challenge": "…", "lifetime": 600}` (seconds)                    | not refused, except by the app's own auth                                                                   |
| `POST <keysPath>` (keyed: `Idempotency-Key: app-attest:<key id>`) | `{"keyID": "…", "attestation": "…", "challenge": "…"}` | `200 {"challenge": "…", "lifetime": 300}`: the first request challenge | `422 {"error": "<code>"}`                                                                                   |
| a signed request                                                  | the headers above                                      | the app's response, maybe with `App-Attest-Challenge`                  | `401` with `WWW-Authenticate: AppAttest error="<code>"`, and `App-Attest-Challenge` when the code wants one |

`App-Attest-Challenge: :<base64>:;lifetime=300` carries a fresh request
challenge. The server sends one with a refusal coded `stale_challenge`,
`missing` or `replayed`, and with any accepted response whose challenge is past
half its lifetime. The authenticator keeps the challenge it received most
recently, and so refreshes without a round trip of its own. It fetches one
(`purpose: "requests"`) in `prepare` only when it holds none, or holds one whose
lifetime has passed by the continuous clock since it arrived.

The enrolment's transport errors (5xx, timeouts) become
`AppAttestServerError.unreachable` with `StoicHTTP`'s classification. A `422` is
`.refused(code:)`.

| Code                  | Means                                                                      | The client                                                                                      |
| --------------------- | -------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `challenge_expired`   | enrolment: the challenge is past its lifetime                              | discards the key (its attestation names that challenge); enrols a new one                       |
| `challenge_used`      | enrolment: the challenge was spent                                         | the same                                                                                        |
| `challenge_invalid`   | enrolment: not a challenge of this server, or for another purpose          | `.enrolmentRefused`                                                                             |
| `key_enrolled`        | enrolment: the key id is on record with another attestation                | `.enrolmentRefused`; discards the key                                                           |
| `invalid_attestation` | enrolment: a check failed                                                  | `.enrolmentRefused`; discards the key                                                           |
| `environment`         | enrolment: a development key to production, or the reverse                 | `.enrolmentRefused`; discards the key                                                           |
| `missing`             | request: the server requires a signature, and there was none               | signs (whatever `signing` says) and replays once                                                |
| `stale_challenge`     | request: the nonce expired, or is not a request challenge of this server   | takes the fresh challenge, signs again, replays once                                            |
| `unknown_key`         | request: no record of the key                                              | discards the key, enrols, signs again, replays once                                             |
| `revoked`             | request: the server revoked the key                                        | discards the key; `.refuse(code: "revoked")`, `.stop`; enrols nothing until `refusedRetryAfter` |
| `replayed`            | request: the counter was seen, or is older than the window                 | signs again (a new counter) and replays once                                                    |
| `invalid`             | request: the signature, digest, components, app id, environment or account | `.refuse(code: "invalid")`, `.stop`, never replayed                                             |
| `unsupported_refused` | request: the server does not accept clients that cannot attest             | `.refuse(code: "unsupported_refused")`, `.stop`                                                 |
| `account_mismatch`    | request: the key was enrolled for another account                          | `.refuse(code: "account_mismatch")`, `.stop`, never replayed                                    |

A repeated enrolment, the same key id with the same attestation object (its
SHA-256 matches `attestationDigest`) and the same account, is answered as a
success with a new request challenge. The counter is unchanged, so a response
that was lost costs nothing. A replayed enrolment therefore cannot reset the
counter.

### Verifying an attestation

`AppAttest.verifyAttestation`, in Apple's order. The first failing check is the
error.

1. **Decode** the attestation object (CBOR, above): a map with `fmt` (text),
   `attStmt` (a map with `x5c`, an array of byte strings, and `receipt`, a byte
   string) and `authData` (a byte string), and nothing else. Otherwise
   `.malformed(what)`. `fmt` must be `"apple-appattest"` (`.format`).
2. **The chain.** `x5c` holds exactly two certificates: the credential
   certificate, then the intermediate. With swift-certificates' `Verifier`, the
   root store `[root]`, `RFC5280Policy(validationTime: now)` and the intermediate
   as the untrusted intermediate, the chain must be credential certificate,
   intermediate, root. Otherwise `.chain(reason)`: expired, not yet valid, a bad
   signature, a constraint, an unhandled critical extension. There is no
   revocation check, because Apple's steps have none.
3. **The nonce.** `nonce = SHA-256(authData ‖ SHA-256(challenge))`. The
   credential certificate's extension `1.2.840.113635.100.8.2` holds DER
   `SEQUENCE { [1] EXPLICIT OCTET STRING }`, parsed with swift-asn1, and its 32
   bytes must equal `nonce`. Otherwise `.nonceMismatch`, or `.malformed` for a
   missing or misshapen extension.
4. **The key.** The credential certificate's public key must be EC P-256. Its
   65-byte X9.63 uncompressed point hashed with SHA-256 must equal the key id,
   base64-decoded to 32 bytes (`.keyIDMismatch`).
5. **The authenticator data.** Offsets 0–31 are `rpIdHash`, which must equal
   `app.rpIDHash` (`.appIDMismatch`). 32 is the flags (recorded, not checked: not
   in Apple's steps). 33–36 are the counter, big-endian, which must be 0
   (`.counterNotZero`). 37–52 are the AAGUID. 53–54 are the credential id
   length, which must be 32. Then the credential id, which must equal the key id
   (`.keyIDMismatch`). The COSE key after it is not read: the key comes from the
   certified certificate. Data shorter than 87 bytes is `.malformed`.
6. **The environment.** The AAGUID is `appattestdevelop` (16 ASCII bytes) for
   development, and `appattest` followed by seven zero bytes for production. It
   must be `environment` (`.environmentMismatch(found:)`, `nil` when it is
   neither).

The result is `Verified<AttestedKey, KeyAttested>`. The challenge's freshness
and single use are the caller's to check before this (the gate does).

### Verifying an assertion

`AppAttest.verifyAssertion`:

1. **Decode**: a map with exactly `signature` and `authenticatorData`, both byte
   strings (`.malformed`). `authenticatorData` is exactly 37 bytes: `rpIdHash`
   (32), flags (1), counter (4, big-endian).
2. **The signature.** `nonce = SHA-256(authenticatorData ‖ SHA-256(clientData))`.
   `signature` is a DER ECDSA signature by the record's public key over the
   message `nonce` with SHA-256, that is, of `SHA-256(nonce)`: swift-crypto's
   `P256.Signing.PublicKey.isValidSignature(_:for: nonce)`
   (`.signatureInvalid`).
3. **`rpIdHash`** must equal the record's app id hash (`.appIDMismatch`).
4. **The record** must be active (`.revoked`).
5. **The counter**, through the window (below): `.replayed(counter:)`,
   `.counterRegressed(counter:highest:)`, or `.counterExhausted` when the highest
   accepted is `UInt32.max`.

The result is `Verified<[UInt8], AppAttested>` over the client data, and the
record with its new counter and revision + 1. Committing that record is how the
counter is kept, so nothing is accepted until the commit succeeds (the gate).

### Verifying a request

`AppAttest.verifyRequest`:

1. **Parse** `Signature-Input` and `Signature`, using only label `attest`.
   Other labels are ignored (RFC 9421 allows several signatures). A missing
   `Signature-Input` or `Signature` is `.signatureMissing`. A covered list that
   lacks a required component is `.componentsMissing`. `idempotency-key` is
   required exactly when the request has the header, and a component not in v1
   is refused. A wrong `alg`, a missing `keyid` or `nonce`, an unexpected
   parameter, or a `keyid` that is not the record's key is `.parameter(name)`.
2. **The body.** `Content-Digest` must be exactly one `sha-256` member, equal to
   the SHA-256 of the body received (`.bodyDigestMismatch`). This is a tampered
   body. A tampered digest header fails at the signature instead.
3. **The base**, rebuilt from the method, configured authority, path, query and
   header values received, and the parameters parsed. Its bytes are the client
   data for `verifyAssertion`.
4. The result is `Verified<AttestedRequest, AppAttested>` and the new record.
   `deriving` decodes the body, with the same evidence.

A proxy that rewrites the path, the query or a covered header produces a base
the app never signed. That is `.signatureInvalid`, which cannot be told apart
from tampering.

### What the server stores and checks

The app's database holds it, through `AppAttestLedger`. The gate composes it.

- **Challenges** need no storage to issue or check. Each is 42 bytes: a version
  (1), the purpose (1 for enrolment, 2 for requests), when it was issued (8
  bytes, big-endian milliseconds since the epoch, by the server's clock), an id
  (16 random bytes from the system's generator), and a tag (the first 16 bytes
  of HMAC-SHA-256, under the first configured key, of the 26 bytes before it).
  `check` refuses a wrong length or version (`.malformed`), a tag no configured
  key gives (`.forged`, compared in constant time by swift-crypto), the other
  purpose (`.wrongPurpose`), an age past the lifetime (`.expired`), and an
  issue time more than `maxSkew` ahead of now (`.fromTheFuture`: another server
  instance's clock is ahead). **An enrolment challenge is single use:** the
  gate records its id with `spend(challenge:until:)`, and a second use is
  `.spent`. Request challenges may be used many times within their lifetime.
  The counter is what makes each assertion count once.
- **Keys**: one `AppAttestKeyRecord` per key id, unique, inserted once. A key id
  already on record is refused, unless the enrolment is the same one (above).
- **Counters.** `AssertionCounter` keeps the highest counter accepted and a
  64-bit map of which of the counters below it were accepted. A counter `c`:

  - above `highest` is accepted: the map shifts by `c - highest`, the new bit is
    set, and `highest` becomes `c`;
  - within `reorderWindow` below `highest` (default 32, at most 63), with its bit
    clear, is accepted and its bit set;
  - within the window with its bit set is `.replayed`;
  - further below is `.counterRegressed`.

  Every counter value is accepted at most once. Concurrent requests that arrive
  out of order are accepted. With `reorderWindow: 0` the rule is Apple's
  literal one, "greater than the stored counter".

- **Committing** a new record uses compare-and-set on `revision`. Two servers
  verifying the same counter at once each produce a record. One commit wins, and
  the other finds the revision moved, reloads, and checks again: its counter's
  bit is now set, so it is `.replayed`. Only the counter is applied again (the
  signature was verified with the same key, which never changes), so the window
  between reading and committing is the ledger's round trip. The gate tries this
  at most 16 times, then refuses `unavailable`, which the app answers with a
  503. That is contention, not a refusal.
- **On a counter regression**: refuse (`replayed`), leave the record unchanged,
  report `attest.counter_regression` at warning level, and **never revoke
  automatically**. A regression is most often an attacker replaying a captured
  assertion. Revoking on it would let anyone who once saw a request lock its
  owner out. A key with repeated regressions is a signal for the app's own risk
  handling, which can call `revoked(because:at:)`.
- **Accounts** (the review's amendment): when a key was enrolled for an account
  and a request arrives with an authenticated account, the gate refuses a
  mismatch, `account_mismatch`: a key lifted from one account's enrolment is
  not another's. A key enrolled anonymously is accepted for any account. This is
  Apple's "unique key for each user account", made enforceable: one compromised
  device cannot serve many accounts under one key.
- **The server's clock** bounds the certificate chain's validity and each
  challenge's age. Nothing reads the client's clock.

### Cancellation

The DeviceCheck calls do not observe cancellation (they are completion-handler
APIs, bridged). The attester checks for it before and after each call. An
assertion is local and brief, and a waiter cancelled during one returns
`.cancelled` when the call ends. An enrolment is never the waiter's, and it
continues. `prepare` and `authenticate` throw a cancellation as `CancellationError`
through the client, as `send` already does (design/19). The server's functions
are pure and synchronous, except the gate's ledger calls, which pass the
ledger's cancellation through.

### Isolation

`AppAttester` is an actor. Its `SecretStore` calls are synchronous and may block
on the Keychain (design/21), so they run on the actor's executor, never on the
main actor. `AppAttestAuthenticator` is a `final class` whose only state, the
current request challenge, sits behind a `Mutex`. `AppAttestGate` is a `Sendable`
struct over the ledger. Every verifier function is pure and `Sendable`.

### Defaults

| Default                      | Value                    | Why                                                                                           |
| ---------------------------- | ------------------------ | --------------------------------------------------------------------------------------------- |
| `enrolmentTimeout`           | 60 s                     | an attestation is one round trip to Apple and one to the app's server; a minute is ample      |
| `unavailableBackoff`         | 2 s × 2ⁿ, capped at 60 s | Apple asks for a later retry with the same inputs; this spaces them without giving up quickly |
| `systemFailureAttempts`      | 3                        | an unexplained system failure deserves a retry, not a loop                                    |
| `keysPerEnrolment`           | 2                        | one spent key is expected (a crash, an expired challenge); a second is a refusal              |
| `refusedRetryAfter`          | 1 h                      | a refused key or enrolment will not succeed in seconds, and each try costs an attestation     |
| `signing`                    | `.unsafeMethods`         | a change is what a server must attribute; a read rarely is, and each signature is work        |
| enrolment challenge lifetime | 10 min                   | covers Apple's retries and the `POST`; past it, one key is wasted, not more                   |
| request challenge lifetime   | 5 min                    | bounds how long an assertion withheld by an attacker stays usable                             |
| fresh challenge sent after   | half the lifetime        | the client refreshes before it needs to                                                       |
| `maxSkew` (server instances) | 30 s                     | servers on NTP disagree by milliseconds; 30 s is a misconfigured host, not drift              |
| `reorderWindow`              | 32                       | 8 requests in flight per host, with retries and redirects, reorder by a handful               |
| gate commit attempts         | 16                       | twice the requests one device has in flight to a host (8): its own parallelism never refuses it |
| CBOR input; header size      | 64 KiB; 16 KiB           | an attestation object is a few KB; a signature header under 1 KB                              |

## Failure modes

| What happens if…                                                              | Then                                                                                                                                                                                                                |
| ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| the device cannot attest (a Mac, the simulator, an extension, older hardware) | `availability` is `.unsupported(reason)`; nothing is generated; `.declare` sends `App-Attest: unsupported;reason=…`, `.fail` sends nothing and fails `authenticationFailed(unsupported)`; `attest.unsupported` once |
| `isSupported` is true and `generateKey` says `featureUnsupported`             | the same, as `.unsupported(.device)`                                                                                                                                                                                |
| a modified app claims to be unsupported                                       | the server gets `Claimed<AppAttestUnsupported>`; `UnsupportedClients` decides; `.refuse` answers `unsupported_refused`                                                                                              |
| many requests arrive while an enrolment is in flight                          | one key, one attestation, one enrolment `POST`; each request waits within its own deadline                                                                                                                          |
| a waiting request's deadline is shorter than the enrolment                    | it fails at its deadline, `authenticationFailed(timed_out)`, nothing sent; the enrolment goes on                                                                                                                    |
| the request that started the enrolment is cancelled                           | the enrolment goes on for the others; that caller gets `CancellationError`                                                                                                                                          |
| Apple's service is unavailable during enrolment                               | `attestKey` is retried with the same key and hash on the backoff; after the timeout, `.serviceUnavailable` (`.retry`), and the next call resumes with the same key                                                  |
| the enrolment challenge's lifetime passes while Apple is unavailable          | a new challenge, the same key                                                                                                                                                                                       |
| the process dies after `generateKey`, before the key id is kept               | the key is orphaned in the Secure Enclave; the next run generates another                                                                                                                                           |
| the process dies after `attestKey`, before the attestation is kept            | the next `attestKey` fails `invalidKey`; the key is discarded and a new one enrolled                                                                                                                                |
| the enrolment's response is lost                                              | the `POST` is resent with the kept attestation; the server answers it as the same enrolment; the counter is unchanged                                                                                               |
| the server refuses the attestation                                            | `.enrolmentRefused(code)`, `.stop`; the key is discarded; no new enrolment for `refusedRetryAfter`                                                                                                                  |
| the enrolment challenge expired between `attestKey` and the `POST`            | the attested key is spent; it is discarded, and enrolment starts again from a new key                                                                                                                               |
| an enrolment challenge is used twice                                          | the second is refused `challenge_used` (`.spent`)                                                                                                                                                                   |
| an attestation is replayed to enrol its key again                             | answered as the same enrolment; the counter is not reset                                                                                                                                                            |
| a key id already on record arrives with another attestation                   | refused `key_enrolled`                                                                                                                                                                                              |
| a key from another app id is presented                                        | `.appIDMismatch`: refused at enrolment (`invalid_attestation`), and per request (`invalid`)                                                                                                                         |
| a development key is presented to production (or the reverse)                 | `.environmentMismatch`, refused `environment`                                                                                                                                                                       |
| the certificate chain does not lead to the root at the server's moment        | `.chain(reason)`, refused `invalid_attestation`                                                                                                                                                                     |
| the credential certificate's nonce is not the one for this challenge and data | `.nonceMismatch`                                                                                                                                                                                                    |
| the key id is not the certified key's hash                                    | `.keyIDMismatch`                                                                                                                                                                                                    |
| the attestation's counter is not zero                                         | `.counterNotZero`                                                                                                                                                                                                   |
| the device's key is invalidated (reinstall, restore, migration)               | `generateAssertion` fails `invalidKey`; the key is discarded, a new one enrolled, the request signed again once; `attest.key_invalidated`                                                                           |
| two requests find the same dead key                                           | one re-enrolment                                                                                                                                                                                                    |
| a fresh key is refused too                                                    | `.keyRefused`, `.stop` until `refusedRetryAfter`; `attest.key_refused` at error                                                                                                                                     |
| `DCError.invalidInput` is thrown                                              | `.invalidInput`: a defect, `attest.invalid_input` at error, `.stop`                                                                                                                                                 |
| `DCError.unknownSystemFailure` is thrown                                      | retried up to 3 times, then `.systemFailure`, `.retry`                                                                                                                                                              |
| the Keychain is locked when the key's record is read                          | `.keychain(.locked)`, `.retry`; no key is generated                                                                                                                                                                 |
| the key's record is absent (a new install, a restore to another device)       | an enrolment                                                                                                                                                                                                        |
| the account changes                                                           | another record, another key                                                                                                                                                                                         |
| a signed request is retried                                                   | every attempt is signed afresh: a new assertion, a new counter, the same idempotency key                                                                                                                            |
| a signed request is redirected within its origin                              | the hop is signed afresh, for its own path and method                                                                                                                                                               |
| a signed request is redirected to another origin                              | the hop carries no signature, digest, `App-Attest` or idempotency key                                                                                                                                               |
| identical `GET`s coalesce                                                     | one flight, signed once when `GET`s are signed                                                                                                                                                                      |
| the server answers `stale_challenge`                                          | the challenge in the refusal is taken; the request is signed again and replayed once                                                                                                                                |
| the server answers `unknown_key`                                              | the key is discarded, a new one enrolled, the request signed and replayed once                                                                                                                                      |
| the server answers `revoked`                                                  | `authenticationFailed(revoked)`, `.stop`; the key is discarded; no enrolment for `refusedRetryAfter`                                                                                                                |
| the server answers `replayed`                                                 | the request is signed again (a new counter) and replayed once                                                                                                                                                       |
| the server answers `missing`                                                  | the request is signed and replayed once                                                                                                                                                                             |
| the server answers `invalid`                                                  | `authenticationFailed(invalid)`, `.stop`; never replayed                                                                                                                                                            |
| a replay is refused again                                                     | the second refusal is the answer                                                                                                                                                                                    |
| a `401` without `AppAttest` arrives                                           | the reauthentication hook runs, as design/19 says                                                                                                                                                                   |
| a request already has a `Signature` header                                    | `authenticationFailed(header_conflict)`; nothing sent                                                                                                                                                               |
| an assertion is replayed                                                      | its counter's bit is set: `.replayed`, refused `replayed`; the record is unchanged                                                                                                                                  |
| a counter regresses below the window                                          | `.counterRegressed`, refused `replayed`; the record is unchanged; `attest.counter_regression`; the key is not revoked                                                                                               |
| assertions arrive out of order within the window                              | each is accepted once                                                                                                                                                                                               |
| two servers accept the same counter at once                                   | one commit wins; the other reloads, finds the bit set, and refuses `replayed`                                                                                                                                       |
| commits keep conflicting                                                      | after 16, `unavailable`: the app answers 503; `attest.commit_conflict` at warning                                                                                                                                  |
| a request challenge expires                                                   | `stale_challenge`, with a fresh challenge                                                                                                                                                                           |
| a challenge is forged, altered, or from another server                        | `.forged`: `stale_challenge` for requests, `challenge_invalid` for enrolment                                                                                                                                        |
| an enrolment challenge is used for requests, or the reverse                   | `.wrongPurpose`, refused the same way                                                                                                                                                                               |
| a server instance's clock is ahead                                            | challenges it issued up to 30 s ahead are accepted; beyond, `.fromTheFuture`                                                                                                                                        |
| the server's clock is wrong for the certificates                              | `.chain(expired \| notYetValid)`                                                                                                                                                                                    |
| the client's clock is wrong                                                   | nothing: it is never read                                                                                                                                                                                           |
| the body is altered                                                           | `.bodyDigestMismatch`, refused `invalid`                                                                                                                                                                            |
| the path, query, method or a covered header is altered                        | `.signatureInvalid`, refused `invalid`                                                                                                                                                                              |
| a proxy rewrites the path or the query                                        | `.signatureInvalid`: indistinguishable from tampering                                                                                                                                                               |
| a proxy rewrites `Host`                                                       | nothing: the server uses its configured authority                                                                                                                                                                   |
| the signature covers fewer components than v1 requires                        | `.componentsMissing`, refused `invalid`                                                                                                                                                                             |
| a key enrolled for one account signs for another                              | refused `account_mismatch`                                                                                                                                                                                          |
| a key's counter reaches `UInt32.max`                                          | `.counterExhausted`; the gate removes the record and refuses `unknown_key`, so the client enrols a new key                                                                                                          |
| an attestation or assertion is malformed or hostile CBOR                      | `.malformed(what)`; never a trap, at any input                                                                                                                                                                      |
| a captured request is replayed from another device                            | `replayed` (its counter is spent), or `stale_challenge` once its challenge expires; a new request needs the Secure Enclave key                                                                                      |
| a genuine app signs a check-in with a faked location                          | it verifies: `AppAttested` proves origin and integrity, not truth                                                                                                                                                   |
| an attested request is passed where a person must be authenticated            | it does not compile: `AppAttested` is not `PrincipalEvidence` (design/28)                                                                                                                                           |

## Events

All in `EventCatalog`. Key ids, challenges, assertions, attestation objects and
bodies are never recorded. Accounts and key ids appear only as descriptions at
`.private` privacy, and codes and counts publicly.

| Event                        | Level   | From   | Meaning                                                                      |
| ---------------------------- | ------- | ------ | ---------------------------------------------------------------------------- |
| `attest.enrolled`            | info    | client | a key was enrolled: how long, how many keys it took, whether it replaced one |
| `attest.enrolment_failed`    | warning | client | an enrolment ended without a key: the code, and when it is tried again       |
| `attest.service_unavailable` | notice  | client | Apple's service could not be reached; retrying with the same key in d        |
| `attest.key_invalidated`     | notice  | client | the device's key is gone; enrolling another                                  |
| `attest.key_refused`         | error   | client | a fresh key was refused too                                                  |
| `attest.unsupported`         | notice  | client | this device cannot attest: the reason (once per attester)                    |
| `attest.invalid_input`       | error   | client | DeviceCheck refused Stoic's input: a defect                                  |
| `attest.refused`             | info    | client | the server refused a signed request: the code; replayed or not               |
| `attest.server_enrolled`     | info    | server | a key was enrolled; or a repeated enrolment was answered                     |
| `attest.attestation_refused` | warning | server | an enrolment was refused: the failing check                                  |
| `attest.assertion_refused`   | notice  | server | a request was refused: the failing check (a stale challenge is debug)        |
| `attest.counter_regression`  | warning | server | a counter below the window; the key's id (private) and the distance          |
| `attest.unsupported_client`  | info    | server | a client said it cannot attest: the reason; accepted or refused              |
| `attest.commit_conflict`     | notice  | server | another request of the key committed first; warning on the last attempt     |
| `attest.ledger_failed`       | error   | server | the ledger threw: its error's type; the request was answered `unavailable`   |

The pure functions record nothing. The client's events come from the attester
and the authenticator, and the server's from the gate.

## Testing

App Attest does not run in the simulator or on this Mac, so the suite tests
everything through a stand-in that produces the same bytes a device would, with
the verifier's root injected.

- **`AppAttestStandIn`** (in `StoicAttestation`, behind its trait, as
  `ScriptedTransport` lives in `StoicHTTP`). It creates a test root (P-384) and
  an intermediate (P-384) with swift-certificates. For each key it generates a
  P-256 pair with swift-crypto, a credential certificate carrying the nonce
  extension, and authenticator data with the app id hash, the environment's
  AAGUID and the credential id. Each assertion increments a counter and is
  signed over the nonce. It can be told to: use another app id or environment;
  sign the wrong nonce; leave the counter non-zero; reuse or skip counters;
  issue certificates outside a validity window; put a third certificate in
  `x5c`; emit each CBOR defect the reader refuses; and sign a base other than
  the one sent. Every server row runs against it, with `AppAttestRoot(der:)` set
  to its root.
- **`ScriptedAppAttestService`** (in `StoicApple`) for every client row about the
  key's lifecycle: scripted key ids, attestations and assertions, real
  `DCError(.invalidKey)`, `DCError(.serverUnavailable)` and the other codes,
  delays on the ambient clock, and every call recorded. It is used with
  `InMemorySecretStore` (with `failNext(.locked)`) and a scripted
  `AppAttestServer`, on `TestClock`. Crash points are simulated by dropping the
  attester after each step and opening another on the same store.
- **End to end** (`StoicAttestedHTTPTests`, with the `Attestation` trait, on
  macOS): `HTTPClient` with `AppAttestAuthenticator` over `ScriptedTransport`,
  whose handler runs `AppAttestGate` over `InMemoryAppAttestLedger`. The
  attester's service is the stand-in, through a ten-line adapter in the test
  target. This exercises real signatures, a real chain, retries, redirects
  (same origin and another), each refusal code's replay, concurrent requests
  out of order through the counter window, and enrolment racing a hundred
  requests. 300 repetitions are clean.
- **Properties.** The counter window is checked against a model (a set of
  accepted counters) over 10⁶ random sequences: each counter is accepted at most
  once, every counter above `highest` is accepted, and nothing older than the
  window is. The CBOR and Structured Fields readers never trap on random bytes or
  on mutations of valid inputs, and refuse every mutation that breaks the
  subset. The challenge format round-trips, and every one-bit change is
  `.forged`.
- **Committed vectors**, `Tests/StoicAttestationTests/Vectors/`:

  - `app-attest-v1.json`, generated once by the stand-in (a test that writes it
    when `STOIC_RECORD_VECTORS=1`) and then only read. It holds the test root's
    DER, the app id, the environment, the challenge, the key id, the attestation
    object, the validation moment, assertions with their client data and
    counters, and requests with their parts, their exact signature base, client
    data hash and headers. It also holds negative cases, each with the failure it
    must produce.
  - The worked example above, with its hash.
  - A `README.md` stating the formats, so that a verifier in another language,
    such as Kindora's TypeScript, can be checked against the same bytes.

  - `apple-development.json` (the review's amendment 1): seven attestations and
    assertions captured from iPhones on iOS 14.2 to 14.4, in the development
    environment, from the test resources of an independent Apache-2.0 verifier
    (devicecheck-appattest; source and licence in `NOTICE`). Each is verified
    against Apple's real root at the moment it was made, and refused for the
    wrong app id, environment, challenge or root, and outside its credential
    certificate's three days. Apple publishes no such bytes itself.

- **Compile-fail** (design/28's harness): an `AppAttested` request passed to a
  `PermissionPolicy` as its principal; a `Verified<_, AppAttested>` built outside
  `StoicAttestation`; `AppAttestAuthenticator(attester)` without
  `ifUnsupported:`.
- **Not exercised by the suite**: Apple's production App Attest service, the
  real `DCAppAttestService`, Apple's root as a device presents it, real key
  invalidation, and the `DCError`s a device really throws. The suite proves
  Stoic's verifier against Stoic's understanding of the format. It does not
  prove that understanding matches Apple's. The device check below closes that
  gap once.

### The one-time device check

Done once before 0.7.0 ships, and recorded in this contract's "As built" with
its date, devices and OS versions:

1. A minimal iOS app, `Examples/AppAttestCheck`, an Xcode project outside the
   package build, signed by a team whose App ID has App Attest. Run from Xcode
   on a physical iPhone, so in the development environment, it shows
   `isSupported`, generates a key, attests it over a fixed challenge, and makes
   three assertions over three fixed bases. It prints all of it as one JSON
   document.
2. That document is verified with `StoicAttestation` against `.apple`, at the
   moment it was captured. This checks the nonce extension's encoding and
   criticality, the 37-byte assertion authenticator data, the ECDSA message
   convention and the development AAGUID. It is committed as
   `apple-development.json`, after checking that it holds nothing but the test
   app's identifiers. From then on, the production root is exercised offline in
   every run.
3. The app is deleted and reinstalled, and `generateAssertion` is asked with the
   old key id: record the `DCError`. The documentation implies `invalidKey`.
4. Record `isSupported` in the iOS Simulator, in an app extension, and on any
   iPad, Apple TV, Apple Vision Pro or Apple Watch at hand.
5. Optionally, a TestFlight build gives a production capture
   (`apple-production.json`, the production AAGUID).

## What was verified, and what was not

**Verified against Apple's real bytes** (seven device captures, Apple's root,
two independent downloads of it agreeing on its SHA-256):

- The attestation object's shape: a CBOR map of `fmt` (`apple-appattest`),
  `attStmt` of exactly `x5c` (two certificates) and `receipt`, and `authData`,
  in shortest-form definite lengths that the strict reader accepts.
- The nonce extension `1.2.840.113635.100.8.2`: DER `SEQUENCE { [1] EXPLICIT
  OCTET STRING }` of 32 bytes, `SHA-256(authData ‖ SHA-256(challenge))`, and
  **not critical**.
- The chain: credential certificate, "Apple App Attestation CA 1", Apple App
  Attestation Root CA, valid under RFC 5280 at the capture's moment; the
  credential certificate is valid for **three days** from issue.
- Attestation `authData`: rpIdHash, flags, counter 0, the development AAGUID
  `appattestdevelop`, a 32-byte credential id equal to the key id, and the
  key id as the SHA-256 of the certified X9.63 P-256 point.
- An assertion: a CBOR map of exactly `signature` and `authenticatorData`, the
  data **37 bytes**, and the signature ECDSA P-256 with SHA-256 over the
  message `SHA-256(authenticatorData ‖ SHA-256(clientData))`, so the nonce is
  hashed once more by the scheme. The first assertion's counter is 1.

**Verified against the stand-in only**: the production AAGUID (`appattest`
and seven zero bytes); request signing format v1 and every request-level
check (the format is Stoic's own, held to the committed vectors on both sides);
the gate, the ledger, challenges and the counter window.

**Not verified** (documentation or inference, settled only by the device check
below, which has not been done):

- `isSupported` anywhere but this Mac (`false`, macOS 27.2): devices, the
  simulator, extensions, tvOS, watchOS, visionOS.
- Which `DCError` a reinstall, restore or migration produces, and whether
  `unknownSystemFailure` is ever transient.
- Whether concurrent `generateAssertion` calls are safe and how their counters
  are ordered (the window assumes nothing).
- How the environments are chosen without the `appattest-environment`
  entitlement.
- That the real `DCAppAttestService` behaves as `ScriptedAppAttestService`
  does: a key attests once, an unattested key cannot assert. Those are the
  headers' words.
- Apple's receipt: kept unauthenticated (`AttestedKey.receipt`); verifying it
  belongs to the risk metric (Not built).

## Not built

- **The receipt and Apple's risk metric** (exchanging the receipt with Apple for
  a fraud metric). The receipt is kept in `AttestedKey` for it.
- **DeviceCheck's two bits** (`DCDevice`).
- **Assertions over anything but HTTP.** The attester signs any 32-byte hash, so
  an XPC message or a WebSocket frame could be signed with app code. Only the
  HTTP glue ships.
- **A TypeScript or other verifier.** The format and the vectors make one
  checkable.
- **Ledgers for real databases** (Postgres, Convex). The protocol and an
  in-memory ledger ship.
- **Re-verifying a stored assertion for audit**, without its counter (design/28,
  evidence that survives storage).
- **Per-request single-use challenges** for an endpoint that wants them (Open
  questions).
- **Android's Play Integrity.** The seam is general. A second attester is not in
  scope.

## Decisions

The draft's open questions, as the review settled them.

1. **Challenges are reusable for five minutes**, with the counter window. A
   per-endpoint single-use option is Not built.
2. **The reorder window defaults to 32**; `reorderWindow: 0` is Apple's literal
   rule.
3. **swift-certificates resolves beside swift-crypto 5** (from 1.21.0): no
   hand-written chain validation.
4. **`StoicAttestedHTTP` is a meeting library**, as `StoicSealedKeychain` is.
5. **The signature base is implemented on both sides** and held to the same
   committed vectors.
6. **`.unsafeMethods` is the signing default.**
7. **Account binding**: a key enrolled for an account is refused for another,
   `account_mismatch`; an anonymous key is accepted for any (amendment 3).

## As built

Departures from the reviewed draft, and decisions it left open.

- **Apple's real bytes (amendment 1).** Found and committed: seven device
  captures with their source and licence in `NOTICE`, and Apple's root from
  apple.com, whose SHA-256 matched the root embedded in an independent
  verifier. Every fact of amendment 2 was confirmed by them (What was
  verified). The verifier passed them on its first run.
- **`verifyAttestation` is `async`.** swift-certificates' `Verifier.validate`
  is asynchronous (a policy may fetch). The function is still pure: no state,
  no clock but the `at:` it is given. The validation time is fixed through
  swift-certificates' `FixedExpiryValidationTime` SPI, because its public
  initialiser for a fixed time is deprecated (warnings are errors here).
- **The credential certificate's extensions** are declared handled by a policy
  of their own, so the chain would not fail if Apple marked the nonce
  extension critical. It is not critical in any capture.
- **The receipt is not authenticated.** A mutation inside it is kept as it
  arrived; every other byte of an attestation is authenticated or checked
  (a property test flips bits outside it, and one inside it). Documented on
  `AttestedKey.receipt`.
- **Commits: 16 attempts, and only the counter is applied again.** The draft's
  3, each re-verifying the signature, refused one device's own eight requests
  in flight with a 503 under contention (found by the end-to-end test of a
  hundred requests). The window is now the ledger's round trip, and the bound
  twice a client's per-host concurrency.
- **`account_mismatch`** (amendment 3) replaces the draft's `invalid` with cause
  `account`, on both sides.
- **The authenticator fetches one request challenge at a time** (a
  `SingleFlight`): a hundred requests that find none after an enrolment ask the
  server once, not a hundred times through the enrolment client's bulkhead.
  It fetches only when it holds none or the one it holds has outlived its
  lifetime by the monotonic clock; a stale challenge is therefore usually
  replaced before it is used, and `stale_challenge` is the server's word for
  what the client could not know (another instance's clock, a rotated key).
- **The record has a `refused` phase.** A refused enrolment, a refused fresh
  key and a revoked key are kept with the moment until which nothing is
  enrolled, so a relaunch does not spend another attestation. A record that
  does not decode, or lacks what its phase needs, is treated as absent and
  replaced (its key cannot be used without the rest).
- **`AppAttester.revoked(_:)` and `requestChallenge()`** are additions: the
  authenticator needs a key revoked to hold off enrolment, and the first
  request challenge an enrolment returned.
- **The authenticator's waits.** A key the device lost while signing is
  replaced inside `authenticate`, holding the attempt's host slot: the
  enrolment's requests go through another client, so this cannot deadlock,
  and it happens once per reinstall. A coalesced `GET` waiting in `prepare`
  past its caller's deadline gets the flight's `deadline_exceeded` rejection,
  not `authenticationFailed(timed_out)`; signed requests are not coalesced by
  default (`.unsafeMethods`).
- **A second `.replay` in a hop** is not honoured: the response is the answer
  (a `401` status), and the reauthentication hook does not run for it.
- **`prepare` runs before each send of a hop**: its first, an authenticator
  replay, and a reauthentication replay.
- **`HTTPClient`'s new initialiser is designated**, not `convenience` (the class
  is `final`; the effect is the same). `HTTPOverrides.authenticate` arrives
  through an overload whose parameter has no default, so the existing
  initialiser is unchanged and not an API break. `HTTPError.authenticationFailed`
  is the one listed break.
- **Event reasons never carry a code**: an attempt's outcome is
  `authentication_failed`, `authentication_refused` or `authentication_replay`;
  the code is in the error. `attest.refused` records a code the client knows,
  or `unknown`.
- **Two server events added**: `attest.commit_conflict` and
  `attest.ledger_failed`.
- **The gate's ledger errors, cancellation included, are `unavailable`** (its
  throws are typed). `AppAttestRefusal.status` says 422, 401 or 503.
- **`AppAttestUnsupported`** is declared in `StoicAttestation` too, beside the
  challenge types, for the same reason.
- **`DCError` from another domain**: a `URLError` or `POSIXError` that
  Foundation's table calls transient is retried as `unknownSystemFailure` is;
  anything else is `.systemFailure` at once.
- **The stand-in** makes CBOR defects through the tests' own writer, not
  through its API; it takes `Attesting` for every other way an attestation is
  wrong, and an app id for an assertion.
- **Compile-fail**: `scripts/compile-fail/attestation/` (compiled against the
  trait build by `StoicAttestationTests`, and by check.sh), and
  `scripts/compile-fail/attested-http-without-fallback.swift`.
- **Not done: the one-time device check.** No device, Xcode team or TestFlight
  build was available to this implementation. The real captures above stand in
  for steps 1 and 2 (the formats, Apple's root); steps 3 to 5 (`DCError` after
  a reinstall, `isSupported` elsewhere, a production capture) remain open.
