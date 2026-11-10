#if canImport(DeviceCheck) && canImport(CryptoKit)
import CryptoKit
import Foundation
import Stoic
@testable import StoicApple
@testable import StoicAttestedHTTP
import StoicHTTP
import StoicJSON
import StoicTesting
import Testing

@Suite("App Attest: the request format")
struct AppAttestRequestFormatTests {
    /// design/29's worked example, computed independently when the contract
    /// was drafted (`openssl dgst -sha256`) and again for this test.
    @Test func theWorkedExampleHasItsPinnedHash() throws {
        let body = Array(#"{"event":"e42","at":"site"}"#.utf8)
        let nonce = Array(try #require(Data(base64Encoded: "AQIAAAGabxssAAABAgMEBQYHCAkKCwwNDg+goaKjpKWmp6ipqqusra6v")))
        let digest = AppAttestRequestFormat.contentDigest(of: body)
        #expect(digest == "sha-256=:TFIG1rH3ac1z4inoc/WSdJvUoBvcPaNKY+HcrXjxBAw=:")
        let base = AppAttestRequestFormat.signatureBase(
            method: "POST", authority: "api.example.com", path: "/v1/check-ins", query: "event=e42", contentDigest: digest,
            idempotencyKey: "3f2a9c1e-7b40-4d1a-9e55-0c6b2d8f1a73", keyID: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=", nonce: nonce)
        #expect(base == """
            "@method": POST
            "@authority": api.example.com
            "@path": /v1/check-ins
            "@query": ?event=e42
            "content-digest": sha-256=:TFIG1rH3ac1z4inoc/WSdJvUoBvcPaNKY+HcrXjxBAw=:
            "idempotency-key": 3f2a9c1e-7b40-4d1a-9e55-0c6b2d8f1a73
            "@signature-params": ("@method" "@authority" "@path" "@query" "content-digest" "idempotency-key");keyid="AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=";nonce="AQIAAAGabxssAAABAgMEBQYHCAkKCwwNDg+goaKjpKWmp6ipqqusra6v";alg="apple-app-attest"
            """)
        #expect(base.utf8.count == 457)
        #expect(Data(AppAttestRequestFormat.clientDataHash(of: base)).base64EncodedString() == "Slmfi7Tpym02yJb133bgVo8qJ4JcehJjSYX0vDUVz1U=")
        #expect(AppAttestRequestFormat.contentDigest(of: []) == AppAttestRequestFormat.emptyBodyDigest)
    }

    /// The signer is held to the vectors the server's verifier is held to
    /// (StoicAttestationTests/Vectors/app-attest-v1.json).
    @Test func theSignerBuildsTheCommittedVectorsBases() throws {
        struct Vector: Decodable {
            let name, method, authority, path, query, body, nonce, base, clientDataHash: String
            let idempotencyKey: String?
            let failure: String?
            let headers: [[String]]
        }
        struct File: Decodable {
            let keyID: String
            let requests: [Vector]
        }
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "StoicAttestationTests/Vectors/app-attest-v1.json")
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        let signed = file.requests.filter { $0.failure == nil }
        #expect(signed.count == 4)
        for vector in signed {
            let body = Array(try #require(Data(base64Encoded: vector.body)))
            let digest = AppAttestRequestFormat.contentDigest(of: body)
            #expect(vector.headers.contains([ "content-digest", digest ]), "\(vector.name): the same Content-Digest")
            let base = AppAttestRequestFormat.signatureBase(
                method: vector.method, authority: vector.authority, path: vector.path, query: vector.query, contentDigest: digest,
                idempotencyKey: vector.idempotencyKey, keyID: file.keyID, nonce: Array(try #require(Data(base64Encoded: vector.nonce))))
            #expect(base == vector.base, "\(vector.name)")
            #expect(Data(AppAttestRequestFormat.clientDataHash(of: base)).base64EncodedString() == vector.clientDataHash)
            // And from an HTTPRequest, as the authenticator builds it.
            var components = URLComponents()
            components.scheme = "https"
            components.host = vector.authority
            components.percentEncodedPath = vector.path
            components.percentEncodedQuery = vector.query.isEmpty ? nil : vector.query
            let request = HTTPRequest(
                method: HTTPMethod(rawValue: vector.method), target: .url(try #require(components.url)),
                headers: vector.idempotencyKey.map { ["Idempotency-Key": $0] } ?? [:], body: body.isEmpty ? nil : body)
            #expect(try Statement(request).base(keyID: file.keyID, nonce: Array(try #require(Data(base64Encoded: vector.nonce)))) == vector.base)
        }
    }

    @Test func theStatementTakesTheRequestAsSent() throws {
        let request = HTTPRequest(
            method: .post, target: .url(URL(string: "https://API.Example.com:443/v1/a%20b?x=1&y=%2F")!),
            headers: ["Idempotency-Key": "k1"], body: [1, 2, 3])
        let statement = try Statement(request)
        #expect(statement.method == "POST")
        #expect(statement.authority == "api.example.com", "lower case, the default port left out")
        #expect(statement.path == "/v1/a%20b", "percent-encoded, exactly as sent")
        #expect(statement.query == "x=1&y=%2F")
        #expect(statement.idempotencyKey == "k1")
        #expect(statement.contentDigest == AppAttestRequestFormat.contentDigest(of: [1, 2, 3]))
        let other = try Statement(HTTPRequest(method: .get, target: .url(URL(string: "https://api.example.com:8443")!)))
        #expect(other.authority == "api.example.com:8443" && other.path == "/" && other.query == "" && other.idempotencyKey == nil)
        #expect(other.contentDigest == AppAttestRequestFormat.emptyBodyDigest)
        #expect(other.base(keyID: "k", nonce: [1]).contains("\"@query\": ?\n"), "? alone when there is no query")
    }

    @Test func theClientsHeaderParsersAreStrict() {
        #expect(AppAttestHeaders.challenge(":AQI=:;lifetime=300") == AppAttestChallenge(bytes: [1, 2], lifetime: .seconds(300)))
        for bad in ["AQI=;lifetime=300", ":AQI=:", ":AQI=:;lifetime=", ":AQI=:;lifetime=-1", ":A Q:;lifetime=3", "::;lifetime=3",
                    ":AQI=:;lifetime=3;x=1", ":AQI=:;Lifetime=3"] {
            #expect(AppAttestHeaders.challenge(bad) == nil, "\(bad)")
        }
        #expect(AppAttestHeaders.errorCode([#"AppAttest error="stale_challenge""#]) == "stale_challenge")
        #expect(AppAttestHeaders.errorCode([#"Bearer realm="x", AppAttest error="replayed""#]) == "replayed")
        #expect(AppAttestHeaders.errorCode([#"Bearer error="invalid_token""#]) == nil, "not ours")
        #expect(AppAttestHeaders.errorCode([#"AppAttest error="a", AppAttest error="b""#]) == nil, "two answers are no answer")
        #expect(AppAttestHeaders.errorCode([#"AppAttest error="Stale""#]) == nil)
        #expect(AppAttestHeaders.errorCode([#"AppAttest error=stale"#]) == nil)
    }
}

@Suite("App Attest: the authenticator")
struct AppAttestAuthenticatorTests {
    // MARK: Signing

    @Test func aPostIsSignedWithItsStatementAndAGetIsNot() async throws {
        let rig = await AttestedRig()
        rig.scriptEnrolment()
        rig.transport.on(.post("/v1/check-ins", json: [:]), respond: [.status(201)])
        rig.transport.on(.get("/v1/events"), respond: [.json("[]")])
        let body: JSONValue = ["event": "e42"]
        _ = try await rig.outcome(.post("/v1/check-ins?event=e42", json: body), key: IdempotencyKey(rawValue: "k1")).get()
        _ = try await rig.outcome(.get("/v1/events")).get()
        let post = try #require(rig.sent(to: "/v1/check-ins").first)
        let (keyID, nonce) = try #require(signatureParameters(post))
        #expect(keyID == "key-1")
        #expect(nonce == "AgE=", "the first request challenge, from the enrolment")
        #expect(post.headers["Content-Digest"] == AppAttestRequestFormat.contentDigest(of: body.encoded()))
        #expect(post.headers["Signature-Input"]?.hasPrefix(#"attest=("@method" "@authority" "@path" "@query" "content-digest" "idempotency-key");"#) == true)
        let base = AppAttestRequestFormat.signatureBase(
            method: "POST", authority: "api.example.com", path: "/v1/check-ins", query: "event=e42",
            contentDigest: try #require(post.headers["Content-Digest"]), idempotencyKey: "k1", keyID: "key-1", nonce: [2, 1])
        #expect(assertion(of: post) == "assertion:1:key-1:\(hex(AppAttestRequestFormat.clientDataHash(of: base)))", "signed over the statement's hash")
        let get = try #require(rig.sent(to: "/v1/events").first)
        #expect(get.headers["Signature"] == nil, ".unsafeMethods by default")
        #expect(rig.sent(to: "/app-attest/keys").first?.headers["Idempotency-Key"] == "app-attest:key-1")
        #expect(rig.sent(to: "/app-attest/keys").first?.headers["Signature"] == nil)
    }

    @Test(.failureMode("design/29", "a signed request is retried"))
    func everyRetryIsSignedAfresh() async throws {
        let rig = await AttestedRig()
        rig.scriptEnrolment()
        rig.transport.on(.post("/v1/check-ins", json: [:]), respond: [.status(503), .status(201)])
        let task = await rig.run { rig.start(.post("/v1/check-ins", json: [:]), key: IdempotencyKey(rawValue: "k1")) }
        await rig.run {
            // The attempt's own timeout is a sleeper too: wait for the failure, then its backoff.
            await eventually { rig.events.events(named: "retry.attempt_failed").count == 1 && rig.clock.sleeperCount == 1 }
            _ = await rig.clock.advanceToNextDeadline()
        }
        #expect(try await task.value.status == 201)
        let attempts = rig.sent(to: "/v1/check-ins")
        #expect(attempts.compactMap(assertion).map { $0.split(separator: ":")[1] } == ["1", "2"], "a new assertion, a new counter")
        #expect(Set(attempts.map { $0.headers["Idempotency-Key"] }) == ["k1"], "the same idempotency key")
    }

    @Test(.failureMode("design/29", "a signed request is redirected within its origin"), .failureMode("design/29", "a signed request is redirected to another origin"))
    func redirectsAreSignedWithinTheOriginAndNeverBeyond() async throws {
        let rig = await AttestedRig()
        rig.scriptEnrolment()
        rig.transport.on(.post("/v1/a", json: [:]), respond: [.status(307, headers: ["Location": "/v1/b"])])
        rig.transport.on(.post("/v1/b", json: [:]), respond: [.status(307, headers: ["Location": "https://cdn.example.net/c"])])
        rig.transport.on(HTTPRequest(method: .post, target: .url(URL(string: "https://cdn.example.net/c")!)), respond: [.status(201)])
        _ = try await rig.outcome(.post("/v1/a", json: [:]), key: IdempotencyKey(rawValue: "k1")).get()
        let a = try #require(rig.sent(to: "/v1/a").first)
        let b = try #require(rig.sent(to: "/v1/b").first)
        let c = try #require(rig.sent(to: "/c").first)
        #expect(assertion(of: a) != nil && assertion(of: b) != nil)
        #expect(assertion(of: a) != assertion(of: b), "the hop is signed afresh, for its own path")
        for header in ["Signature", "Signature-Input", "Content-Digest", "App-Attest", "Idempotency-Key", "Authorization"] {
            #expect(c.headers[header] == nil, "\(header) does not cross an origin")
        }
    }

    @Test(.failureMode("design/29", "a request already has a Signature header"))
    func aRequestThatIsAlreadySignedIsRefusedBeforeItIsSent() async throws {
        let rig = await AttestedRig()
        rig.scriptEnrolment()
        rig.transport.on(.post("/v1/check-ins", json: [:]), respond: [.status(201)])
        let outcome = await rig.outcome(.post("/v1/check-ins", json: [:], headers: ["Signature": "other=:AA==:"]))
        guard case .failure(let error as HTTPError) = outcome else { Issue.record("sent: \(outcome)"); return }
        #expect(error == .authenticationFailed(AppAttestAuthenticator.error("header_conflict", .stop), attempts: 0))
        #expect(rig.sent(to: "/v1/check-ins").isEmpty)
    }

    // MARK: Unsupported

    @Test(.failureMode("design/29", "the device cannot attest (a Mac, the simulator, an extension, older hardware)"))
    func anUnsupportedDeviceDeclaresOrFailsAsTheAppChose() async throws {
        let simulator = AppAttestPlatform(isSimulator: true, isMac: false, isAppExtension: false, isWatch: false)
        let declaring = await AttestedRig(ifUnsupported: .declare, platform: simulator)
        declaring.transport.on(.post("/v1/check-ins", json: [:]), respond: [.status(201)])
        _ = try await declaring.outcome(.post("/v1/check-ins", json: [:])).get()
        let declared = try #require(declaring.sent(to: "/v1/check-ins").first)
        #expect(declared.headers["App-Attest"] == "unsupported;reason=simulator")
        #expect(declared.headers["Signature"] == nil && declaring.service.calls.isEmpty)

        let failing = await AttestedRig(ifUnsupported: .fail, platform: simulator)
        let outcome = await failing.outcome(.post("/v1/check-ins", json: [:]))
        guard case .failure(let error as HTTPError) = outcome else { Issue.record("sent: \(outcome)"); return }
        #expect(error == .authenticationFailed(AppAttestAuthenticator.error("unsupported", .stop), attempts: 0))
        #expect(error.neverReachedBackend && error.retryDecision == .stop)
        #expect(failing.transport.requestCount == 0, "nothing sent")
    }

    // MARK: The server's answers

    static func refusal(_ code: String, challenge: String? = nil) -> ScriptedTransport.Step {
        var headers: HTTPHeaders = ["WWW-Authenticate": #"AppAttest error="\#(code)""#]
        if let challenge { headers["App-Attest-Challenge"] = ":\(challenge):;lifetime=300" }
        return .status(401, headers: headers)
    }

    @Test(.failureMode("design/29", "the server answers stale_challenge"))
    func aStaleChallengeIsReplacedFromTheRefusalAndTheRequestSignedAgain() async throws {
        let rig = await AttestedRig()
        rig.scriptEnrolment()
        rig.transport.on(.post("/v1/check-ins", json: [:]), respond: [Self.refusal("stale_challenge", challenge: "AgI="), .status(201)])
        _ = try await rig.outcome(.post("/v1/check-ins", json: [:])).get()
        let nonces = rig.sent(to: "/v1/check-ins").compactMap { signatureParameters($0)?.nonce }
        #expect(nonces == ["AgE=", "AgI="], "the refusal's fresh challenge")
        #expect(rig.sent(to: "/app-attest/challenge").count == 1, "only the enrolment's: no round trip of its own")
        #expect(rig.renewals.value == 0)
        #expect(rig.events.events(named: "attest.refused").first?["code"]?.description == "stale_challenge")
    }

    @Test(.failureMode("design/29", "the server answers unknown_key"))
    func anUnknownKeyIsReplacedAndTheRequestSignedAgain() async throws {
        let rig = await AttestedRig()
        rig.scriptEnrolment()
        rig.transport.on(.post("/v1/check-ins", json: [:]), respond: [Self.refusal("unknown_key"), .status(201)])
        _ = try await rig.outcome(.post("/v1/check-ins", json: [:])).get()
        #expect(rig.sent(to: "/v1/check-ins").compactMap { signatureParameters($0)?.keyID } == ["key-1", "key-2"])
        #expect(rig.sent(to: "/app-attest/keys").count == 2)
    }

    @Test(.failureMode("design/29", "the server answers revoked"))
    func aRevokedKeyEndsTheCallAndHoldsOffEnrolment() async throws {
        let rig = await AttestedRig()
        rig.scriptEnrolment()
        rig.transport.on(.post("/v1/check-ins", json: [:]), respond: [Self.refusal("revoked")], then: .status(201))
        let outcome = await rig.outcome(.post("/v1/check-ins", json: [:]))
        guard case .failure(let error as HTTPError) = outcome else { Issue.record("not refused: \(outcome)"); return }
        #expect(error == .authenticationFailed(AppAttestAuthenticator.error("revoked", .stop), attempts: 1))
        #expect(rig.renewals.value == 0)
        let again = await rig.outcome(.post("/v1/check-ins", json: [:]))
        guard case .failure(let held as HTTPError) = again else { Issue.record("enrolled again: \(again)"); return }
        #expect(held == .authenticationFailed(AppAttestAuthenticator.error("enrolment_refused", .stop), attempts: 0))
        #expect(rig.service.calls(.generateKey).count == 1, "nothing enrolled for refusedRetryAfter")
    }

    @Test(.failureMode("design/29", "the server answers replayed"))
    func aReplayedCounterIsSignedAgainWithANewOne() async throws {
        let rig = await AttestedRig()
        rig.scriptEnrolment()
        rig.transport.on(.post("/v1/check-ins", json: [:]), respond: [Self.refusal("replayed"), .status(201)])
        _ = try await rig.outcome(.post("/v1/check-ins", json: [:])).get()
        let counters = rig.sent(to: "/v1/check-ins").compactMap(assertion).map { $0.split(separator: ":")[1] }
        #expect(counters == ["1", "2"])
    }

    @Test(.failureMode("design/29", "the server answers missing"))
    func aMissingSignatureIsAddedToARequestNotSignedByDefault() async throws {
        let rig = await AttestedRig()
        rig.scriptEnrolment()
        rig.transport.on(.get("/v1/me"), respond: [Self.refusal("missing"), .json("{}")])
        _ = try await rig.outcome(.get("/v1/me")).get()
        let sent = rig.sent(to: "/v1/me")
        #expect(sent.count == 2)
        #expect(sent[0].headers["Signature"] == nil && sent[1].headers["Signature"] != nil, "signed, whatever `signing` says, and replayed once")
    }

    @Test(.failureMode("design/29", "the server answers invalid"))
    func anInvalidSignatureIsNeverReplayed() async throws {
        let rig = await AttestedRig()
        rig.scriptEnrolment()
        rig.transport.on(.post("/v1/check-ins", json: [:]), respond: [Self.refusal("invalid")], then: .status(201))
        let outcome = await rig.outcome(.post("/v1/check-ins", json: [:]))
        guard case .failure(let error as HTTPError) = outcome else { Issue.record("not refused: \(outcome)"); return }
        #expect(error == .authenticationFailed(AppAttestAuthenticator.error("invalid", .stop), attempts: 1))
        #expect(rig.sent(to: "/v1/check-ins").count == 1)
    }

    @Test(.failureMode("design/29", "a replay is refused again"))
    func theSecondRefusalIsTheAnswer() async throws {
        let rig = await AttestedRig()
        rig.scriptEnrolment()
        rig.transport.on(.post("/v1/check-ins", json: [:]), respond: [Self.refusal("replayed"), Self.refusal("replayed")], then: .status(201))
        let outcome = await rig.outcome(.post("/v1/check-ins", json: [:]))
        guard case .failure(let error as HTTPError) = outcome, case .status(401, _, _, _, let attempts) = error else {
            Issue.record("expected the second 401: \(outcome)")
            return
        }
        #expect(attempts == 2)
        #expect(rig.renewals.value == 0)
    }

    @Test(.failureMode("design/29", "a 401 without AppAttest arrives"))
    func anotherSchemes401ReachesTheReauthenticationHook() async throws {
        let rig = await AttestedRig()
        rig.scriptEnrolment()
        rig.transport.on(.post("/v1/check-ins", json: [:]), respond: [.status(401, headers: ["WWW-Authenticate": "Bearer"]), .status(201)])
        _ = try await rig.outcome(.post("/v1/check-ins", json: [:])).get()
        #expect(rig.renewals.value == 1)
        #expect(rig.sent(to: "/v1/check-ins").last?.headers["Authorization"] == "Bearer t2")
    }

    @Test(.failureMode("design/29", "the device's key is invalidated (reinstall, restore, migration)"))
    func aKeyLostOnTheDeviceIsReplacedWhileSigning() async throws {
        let rig = await AttestedRig()
        rig.scriptEnrolment()
        rig.transport.on(.post("/v1/check-ins", json: [:]), respond: [], then: .status(201))
        _ = try await rig.outcome(.post("/v1/check-ins", json: [:])).get()
        rig.service.invalidate("key-1")
        _ = try await rig.outcome(.post("/v1/check-ins", json: [:])).get()
        #expect(rig.sent(to: "/v1/check-ins").compactMap { signatureParameters($0)?.keyID } == ["key-1", "key-2"])
        #expect(rig.events.events(named: "attest.key_invalidated").count == 1)
    }

    @Test(.failureMode("design/29", "many requests arrive while an enrolment is in flight"))
    func requestsWaitingForTheEnrolmentShareIt() async throws {
        let rig = await AttestedRig()
        rig.scriptEnrolment()
        rig.service.delay(.attestKey, by: .seconds(1))
        rig.transport.on(.post("/v1/check-ins", json: [:]), respond: [], then: .status(201))
        let requests = await rig.run { (0..<20).map { _ in rig.start(.post("/v1/check-ins", json: [:])) } }
        await rig.run {
            // Every request waiting, and the device's delay asleep beside the enrolment's timeout.
            await eventually { await rig.attester.enrolmentWaiters == 20 }
            await eventually { rig.service.calls(.attestKey).count == 1 && rig.clock.sleeperCount == 2 }
            await rig.clock.advance(by: .seconds(1))
        }
        for request in requests { #expect(try await request.value.status == 201) }
        #expect(rig.service.calls(.generateKey).count == 1 && rig.service.calls(.attestKey).count == 1)
        #expect(rig.sent(to: "/app-attest/keys").count == 1)
        #expect(Set(rig.sent(to: "/v1/check-ins").compactMap(assertion)).count == 20, "each its own assertion")
    }

    // MARK: The wire protocol

    @Test func theEnrolmentServerSpeaksTheWireProtocol() async throws {
        let rig = await AttestedRig()
        rig.transport.on(.post("/app-attest/challenge", json: [:]), respond: [.json(#"{"challenge":"AQE=","lifetime":600}"#), .json("{}")])
        rig.transport.on(.post("/app-attest/keys", json: [:]),
                         respond: [.json(#"{"error":"invalid_attestation"}"#, status: 422), .status(503), .json(#"{"error":"made_up"}"#, status: 422)])
        let enrolment = await rig.run { HTTPClient(base: api, policy: HTTPPolicy(schedule: Schedule.immediate.attempts(1)), transport: rig.transport) }
        let server = HTTPAppAttestServer.http(enrolment)
        let challenge = try await rig.run { () async throws -> AppAttestChallenge in try await server.challenge(for: .enrolment) }
        #expect(challenge == AppAttestChallenge(bytes: [1, 1], lifetime: .seconds(600)))
        let malformed = await rig.run { () async -> AppAttestServerError? in
            do throws(AppAttestServerError) { _ = try await server.challenge(for: .requests); return nil } catch { return error }
        }
        #expect(malformed == .unreachable(.stop, neverReachedBackend: false), "an answer that is not the protocol")
        let sentPurpose = try JSONValue(parsing: rig.sent(to: "/app-attest/challenge").first?.body ?? []).object?["purpose"]?.string
        #expect(sentPurpose == "enrolment")
        func enrol() async -> AppAttestServerError? {
            await rig.run { () async -> AppAttestServerError? in
                do throws(AppAttestServerError) {
                    _ = try await server.enrol(AppAttestKeyID(base64: "k+/="), attestation: [1, 2], challenge: challenge)
                    return nil
                } catch {
                    return error
                }
            }
        }
        #expect(await enrol() == .refused(code: "invalid_attestation"))
        #expect(await enrol() == .unreachable(.retry, neverReachedBackend: false))
        #expect(await enrol() == .refused(code: "invalid"), "a code this version does not know")
        let body = try JSONValue(parsing: rig.sent(to: "/app-attest/keys").first?.body ?? []).object
        #expect(body?["keyID"]?.string == "k+/=" && body?["attestation"]?.string == "AQI=" && body?["challenge"]?.string == "AQE=")
        #expect(rig.sent(to: "/app-attest/keys").first?.headers["Idempotency-Key"] == "app-attest:k+/=")
    }
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { byte in
        let digits = Array("0123456789abcdef")
        return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]])
    }.joined()
}

func eventually(_ condition: () async -> Bool, sourceLocation: Testing.SourceLocation = #_sourceLocation) async {
    let clock = ContinuousClock()
    let limit = clock.now.advanced(by: .seconds(10))
    while !(await condition()) {
        if clock.now >= limit {
            Issue.record("the condition never became true", sourceLocation: sourceLocation)
            return
        }
        try? await clock.sleep(for: .milliseconds(1))
    }
}
#endif
