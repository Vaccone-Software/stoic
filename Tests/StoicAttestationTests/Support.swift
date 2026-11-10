#if STOIC_ATTESTATION
import Crypto
import Foundation
import Stoic
@testable import StoicAttestation
import StoicTesting
import Synchronization
import Testing

let kindora = try! AppID("A1B2C3D4E5.app.kindora") // stoic:allow(force-try): a literal app id
let serverAuthority = "api.kindora.app"
let challengeKey = Secret(Array(repeating: UInt8(7), count: 32))

func sha256(_ bytes: [UInt8]) -> [UInt8] { Array(SHA256.hash(data: bytes)) }

/// A device (the stand-in), a server (the gate over an in-memory ledger)
/// and a test clock whose wall clock both read.
final class AttestationRig: Sendable {
    let clock = TestClock()
    let events = RecordingInstrumentation()
    let device: AppAttestStandIn
    let ledger: InMemoryAppAttestLedger
    let gate: AppAttestGate

    init(environment: AppAttestEnvironment = .production, reorderWindow: Int = 32, ifUnsupported: UnsupportedClients = .accept,
         ledger: InMemoryAppAttestLedger = InMemoryAppAttestLedger(), gateLedger: (any AppAttestLedger)? = nil) throws {
        device = try AppAttestStandIn(app: kindora, environment: environment, at: TestClock.wallClockStart)
        self.ledger = ledger
        gate = AppAttestGate(
            app: kindora, environment: .production, authority: serverAuthority, root: device.root,
            challenges: try AppAttestChallenges(keys: [challengeKey]), ledger: gateLedger ?? ledger,
            reorderWindow: reorderWindow, ifUnsupported: ifUnsupported)
    }

    func run<R>(_ body: () async throws -> R) async rethrows -> R {
        try await withTestAmbient(clock: clock, events: events) { () async throws -> R in try await body() }
    }

    /// A key, attested over a fresh enrolment challenge.
    func attestedKey(_ attesting: AppAttestStandIn.Attesting = .init()) async throws -> (keyID: String, enrolment: AppAttestEnrolment) {
        let challenge = await run { gate.challenge(.enrolment) }
        let keyID = device.generateKey()
        let attestation = try device.attest(keyID, clientDataHash: sha256(challenge.bytes), attesting)
        return (keyID, AppAttestEnrolment(keyID: keyID, attestation: attestation, challenge: challenge.bytes))
    }

    /// A key enrolled for `account`, and the first request challenge.
    func enrolledKey(account: String? = "volunteer-7") async throws -> (keyID: String, challenge: AppAttestChallenge) {
        let (keyID, enrolment) = try await attestedKey()
        let challenge = try await run { () async throws -> AppAttestChallenge in try await gate.enrol(enrolment, account: account) }
        return (keyID, challenge)
    }

    func enrol(_ enrolment: AppAttestEnrolment, account: String? = "volunteer-7") async -> Result<AppAttestChallenge, AppAttestRefusal> {
        await run {
            do throws(AppAttestRefusal) { return .success(try await gate.enrol(enrolment, account: account)) } catch { return .failure(error) }
        }
    }

    func verify(_ request: SignedRequest, account: String? = "volunteer-7") async -> Result<GateOutcome, AppAttestRefusal> {
        await run {
            do throws(AppAttestRefusal) { return .success(try await gate.verify(request, account: account)) } catch { return .failure(error) }
        }
    }
}

/// What a client sends, built the way the client builds it (format v1).
struct Signing {
    var method = "POST"
    var path = "/v1/check-ins"
    var query = "event=e42"
    var body: [UInt8] = Array(#"{"commitment":"c7","latitude":51.5,"longitude":-0.12}"#.utf8)
    var idempotencyKey: String? = "3f2a9c1e-7b40-4d1a-9e55-0c6b2d8f1a73"
    var authority = serverAuthority
    var counter: UInt32?
    var app: AppID?
    var extraHeaders: [(name: String, value: String)] = []

    var contentDigest: String { "sha-256=:\(Base64.encode(sha256(body))):" }

    func parameters(keyID: String, nonce: [UInt8]) -> String {
        let components = ["@method", "@authority", "@path", "@query", "content-digest"] + (idempotencyKey == nil ? [] : ["idempotency-key"])
        return "(" + components.map { "\"\($0)\"" }.joined(separator: " ") + ");keyid=\"\(keyID)\";nonce=\"\(Base64.encode(nonce))\";alg=\"apple-app-attest\""
    }

    func base(keyID: String, nonce: [UInt8]) -> String {
        AppAttest.signatureBase(
            method: method, authority: self.authority, path: path, query: query, contentDigest: contentDigest,
            idempotencyKey: idempotencyKey, parameters: parameters(keyID: keyID, nonce: nonce))
    }

    /// The request, signed by `keyID` on `device` with challenge `nonce`.
    func signed(by keyID: String, on device: AppAttestStandIn, nonce: [UInt8]) throws -> SignedRequest {
        let assertion = try device.assert(keyID, clientDataHash: sha256(Array(base(keyID: keyID, nonce: nonce).utf8)), counter: counter, app: app)
        return request(signatureInput: "attest=" + parameters(keyID: keyID, nonce: nonce), signature: "attest=:\(Base64.encode(assertion)):")
    }

    func request(signatureInput: String?, signature: String?) -> SignedRequest {
        var headers: [(name: String, value: String)] = [("Content-Digest", contentDigest), ("Host", "internal-lb.local")]
        if let idempotencyKey { headers.append(("Idempotency-Key", idempotencyKey)) }
        if let signatureInput { headers.append(("Signature-Input", signatureInput)) }
        if let signature { headers.append(("Signature", signature)) }
        return SignedRequest(method: method, path: path, query: query, headers: headers + extraHeaders, body: body)
    }
}

/// A random number generator a test can seed.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
#endif
