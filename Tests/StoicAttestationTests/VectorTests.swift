#if STOIC_ATTESTATION
import Foundation
import Stoic
@testable import StoicAttestation
import StoicTesting
import Testing

/// Vectors/app-attest-v1.json: an enrolment and signed requests the stand-in
/// made once, with their exact signature bases and client data hashes, and
/// negative cases with the failure each must produce. A verifier in another
/// language is held to the same bytes; so is StoicAttestedHTTP's signer.
struct VectorFile: Codable, Sendable {
    struct Request: Codable, Sendable {
        var name: String
        var method: String
        var authority: String
        var path: String
        var query: String
        var body: String
        var idempotencyKey: String?
        var nonce: String
        var counter: UInt32
        var base: String
        var clientDataHash: String
        var headers: [[String]]
        /// The `AssertionFailure.check` it must fail with; `nil` when it verifies.
        var failure: String?
    }

    var format = "app-attest v1"
    var root: String
    var app: String
    var environment: String
    var validAt: String
    var challenge: String
    var keyID: String
    var attestation: String
    var requests: [Request]
    var workedExample: WorkedExample

    struct WorkedExample: Codable, Sendable {
        var base: String
        var clientDataHash: String
    }

    static let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Vectors/app-attest-v1.json")
}

@Suite("App Attest: the committed vectors")
struct VectorTests {
    /// Writes the vectors when STOIC_RECORD_VECTORS=1; they are committed, and
    /// from then on only read.
    @Test func recordTheVectorsWhenAsked() async throws {
        guard ProcessInfo.processInfo.environment["STOIC_RECORD_VECTORS"] == "1" else { return }
        let rig = try AttestationRig()
        let (keyID, enrolment) = try await rig.attestedKey()
        let nonce = await rig.run { rig.gate.challenge(.requests) }.bytes
        var requests: [VectorFile.Request] = []
        func add(_ name: String, _ signing: Signing, failure: String? = nil, mutate: ((SignedRequest) -> SignedRequest)? = nil) throws {
            let signed = try signing.signed(by: keyID, on: rig.device, nonce: nonce)
            let sent = mutate?(signed) ?? signed
            let base = signing.base(keyID: keyID, nonce: nonce)
            requests.append(VectorFile.Request(
                name: name, method: sent.method, authority: serverAuthority, path: sent.path, query: sent.query, body: Base64.encode(sent.body),
                idempotencyKey: signing.idempotencyKey, nonce: Base64.encode(nonce), counter: signing.counter ?? 0, base: base,
                clientDataHash: Base64.encode(sha256(Array(base.utf8))), headers: headers(of: sent).map { [$0.name, $0.value] },
                failure: failure))
        }
        var first = Signing()
        first.counter = 1
        try add("a keyed POST with a query", first)
        var get = Signing()
        get.method = "GET"; get.path = "/v1/events"; get.query = ""; get.body = []; get.idempotencyKey = nil; get.counter = 2
        try add("a GET with no query, no body and no idempotency key", get)
        var encoded = Signing()
        encoded.path = "/v1/files/a%20b"; encoded.query = "q=%2F&r=1"; encoded.counter = 4
        try add("a percent-encoded path and query, counter 4 before 3", encoded)
        var three = Signing()
        three.counter = 3; three.idempotencyKey = "k3"
        try add("counter 3 after 4, within the window", three)
        try add("the first request again", first, failure: "replayed")
        try add("a body altered", first, failure: "body_digest") {
            SignedRequest(method: $0.method, path: $0.path, query: $0.query, headers: headers(of: $0), body: Array("{}".utf8))
        }
        try add("a path altered", first, failure: "signature") {
            SignedRequest(method: $0.method, path: "/v1/other", query: $0.query, headers: headers(of: $0), body: $0.body)
        }
        let file = VectorFile(
            root: Base64.encode(rig.device.root.der), app: kindora.description, environment: "production",
            validAt: TestClock.wallClockStart.description, challenge: Base64.encode(enrolment.challenge), keyID: keyID,
            attestation: Base64.encode(enrolment.attestation), requests: requests,
            workedExample: VectorFile.WorkedExample(base: Self.workedExampleBase, clientDataHash: "Slmfi7Tpym02yJb133bgVo8qJ4JcehJjSYX0vDUVz1U="))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(file).write(to: VectorFile.url)
    }

    static let workedExampleBase = """
        "@method": POST
        "@authority": api.example.com
        "@path": /v1/check-ins
        "@query": ?event=e42
        "content-digest": sha-256=:TFIG1rH3ac1z4inoc/WSdJvUoBvcPaNKY+HcrXjxBAw=:
        "idempotency-key": 3f2a9c1e-7b40-4d1a-9e55-0c6b2d8f1a73
        "@signature-params": ("@method" "@authority" "@path" "@query" "content-digest" "idempotency-key");keyid="AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=";nonce="AQIAAAGabxssAAABAgMEBQYHCAkKCwwNDg+goaKjpKWmp6ipqqusra6v";alg="apple-app-attest"
        """

    static func file() throws -> VectorFile {
        try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: VectorFile.url))
    }

    @Test func theVectorsVerifyAsCommitted() async throws {
        let file = try Self.file()
        let root = try AppAttestRoot(der: try #require(Base64.canonical(file.root)))
        let moment = try #require(Moment(rfc3339: file.validAt))
        let key = try await AppAttest.verifyAttestation(
            try #require(Base64.canonical(file.attestation)), keyID: file.keyID, challenge: try #require(Base64.canonical(file.challenge)),
            app: try AppID(file.app), environment: .production, root: root, at: moment)
        var record = AppAttestKeyRecord(enrolling: key, account: nil, attestation: try #require(Base64.canonical(file.attestation)), at: moment)
        #expect(file.requests.count == 7)
        for vector in file.requests {
            let request = SignedRequest(
                method: vector.method, path: vector.path, query: vector.query,
                headers: vector.headers.map { (name: $0[0], value: $0[1]) }, body: try #require(Base64.canonical(vector.body)))
            let parsed = try #require(try AppAttest.parse(request))
            let base = AppAttest.signatureBase(
                method: vector.method, authority: vector.authority, path: vector.path, query: vector.query,
                contentDigest: try #require(request.values("content-digest").first), idempotencyKey: vector.idempotencyKey,
                parameters: parsed.parameters)
            if vector.failure == nil {
                #expect(base == vector.base, "\(vector.name): the base the server rebuilds is the one signed")
                #expect(Base64.encode(sha256(Array(base.utf8))) == vector.clientDataHash)
            }
            do throws(AssertionFailure) {
                let accepted = try AppAttest.verifyRequest(request, authority: vector.authority, record: record)
                #expect(vector.failure == nil, "\(vector.name) verified, but must fail \(vector.failure ?? "")")
                #expect(accepted.verified.evidence.counter == vector.counter)
                record = accepted.record
            } catch {
                #expect(error.check == vector.failure, "\(vector.name): \(error)")
            }
        }
        #expect(file.workedExample.base == Self.workedExampleBase)
        #expect(Base64.encode(sha256(Array(file.workedExample.base.utf8))) == file.workedExample.clientDataHash)
    }
}
#endif
