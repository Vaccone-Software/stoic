#if STOIC_ATTESTATION && canImport(DeviceCheck) && canImport(CryptoKit)
import DeviceCheck
import Foundation
import Stoic
@testable import StoicApple
@testable import StoicAttestedHTTP
import StoicAttestation
import StoicHTTP
import StoicJSON
import StoicTesting
import Synchronization
import Testing

/// The stand-in as the device's App Attest service: the ten-line adapter.
struct StandInService: StoicApple.AppAttestService {
    let device: AppAttestStandIn
    var isSupported: Bool { true }
    func generateKey() async throws -> String { device.generateKey() }
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        do { return Data(try device.attest(keyID, clientDataHash: Array(clientDataHash))) } catch { throw DCError(.invalidKey) }
    }
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        do { return Data(try device.assert(keyID, clientDataHash: Array(clientDataHash))) } catch { throw DCError(.invalidKey) }
    }
}

/// The app's server, in process: the gate behind design/29's wire protocol,
/// and an API that answers what the gate let through.
final class GateTransport: HTTPTransport {
    let gate: AppAttestGate
    private let state = Mutex<(unavailable: Int, attested: [AttestedRequest], unsigned: [HTTPRequest])>((0, [], []))

    init(gate: AppAttestGate) { self.gate = gate }

    var attested: [AttestedRequest] { state.withLock { $0.attested } }
    var unsigned: [HTTPRequest] { state.withLock { $0.unsigned } }
    func failNext(_ count: Int) { state.withLock { $0.unavailable += count } }

    func send(_ request: HTTPRequest, maxResponseBytes: Int) async throws -> HTTPResponse {
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        guard url.host == "api.example.com" else {
            state.withLock { $0.unsigned.append(request) }
            return HTTPResponse(status: 201)
        }
        switch url.path {
        case "/app-attest/challenge":
            let purpose = try JSONValue(parsing: request.body ?? []).object?["purpose"]?.string
            return Self.json(gate.challenge(purpose == "requests" ? .requests : .enrolment))
        case "/app-attest/keys":
            let enrolment = try JSONDecoder().decode(AppAttestEnrolment.self, from: Data(request.body ?? []))
            do throws(AppAttestRefusal) {
                return Self.json(try await gate.enrol(enrolment, account: "volunteer-7"))
            } catch {
                return HTTPResponse(status: error.status, body: Array(#"{"error":"\#(error.code)"}"#.utf8))
            }
        default:
            if state.withLock({ state -> Bool in
                guard state.unavailable > 0 else { return false }
                state.unavailable -= 1
                return true
            }) {
                return HTTPResponse(status: 503)
            }
            let signed = SignedRequest(
                method: request.method.rawValue, path: components.percentEncodedPath, query: components.percentEncodedQuery ?? "",
                headers: request.headers.fields.map { (name: $0.name, value: $0.value) }, body: request.body ?? [])
            do throws(AppAttestRefusal) {
                switch try await gate.verify(signed, account: "volunteer-7") {
                case .attested(let verified, let fresh):
                    state.withLock { $0.attested.append(verified.value) }
                    var headers: HTTPHeaders = [:]
                    if let fresh { headers["App-Attest-Challenge"] = AppAttestGate.challengeHeader(fresh).value }
                    if url.path == "/v1/a" { headers["Location"] = "/v1/b"; return HTTPResponse(status: 307, headers: headers) }
                    if url.path == "/v1/b" { headers["Location"] = "https://cdn.example.net/c"; return HTTPResponse(status: 307, headers: headers) }
                    return HTTPResponse(status: 201, headers: headers)
                case .unsupported:
                    return HTTPResponse(status: 202)
                }
            } catch {
                return HTTPResponse(status: error.status, headers: HTTPHeaders(gate.headers(for: error).map { ($0.name, $0.value) }))
            }
        }
    }

    static func json(_ challenge: StoicAttestation.AppAttestChallenge) -> HTTPResponse {
        HTTPResponse(status: 200, headers: ["Content-Type": "application/json"],
                     body: Array(#"{"challenge":"\#(Data(challenge.bytes).base64EncodedString())","lifetime":\#(challenge.lifetime.components.seconds)}"#.utf8))
    }
}

/// An app and its server: the attester on the stand-in, the authenticator,
/// the gate over an in-memory ledger, on one test clock.
final class EndToEnd: Sendable {
    let clock = TestClock()
    let events = RecordingInstrumentation()
    let device: AppAttestStandIn
    let ledger = InMemoryAppAttestLedger()
    let transport: GateTransport
    let attester: AppAttester
    let client: HTTPClient

    init() async throws {
        let device = try AppAttestStandIn(app: try AppID("A1B2C3D4E5.app.kindora"), at: TestClock.wallClockStart)
        self.device = device
        let gate = AppAttestGate(
            app: try AppID("A1B2C3D4E5.app.kindora"), environment: .production, authority: "api.example.com", root: device.root,
            challenges: try AppAttestChallenges(keys: [Secret(Array(repeating: 3, count: 32))]), ledger: ledger, ifUnsupported: .refuse)
        let transport = GateTransport(gate: gate)
        self.transport = transport
        (attester, client) = await withTestAmbient(clock: clock, events: events) {
            let attester = AppAttester(
                account: "volunteer-7", secrets: InMemorySecretStore(), server: .http(HTTPClient(base: api, transport: transport, label: "app-attest")),
                service: StandInService(device: device), policy: .standard, platform: phone)
            // A queue deep enough for a hundred requests at once: the host's
            // eight slots are StoicHTTP's own bound, not App Attest's.
            let client = HTTPClient(
                base: api, policy: HTTPPolicy(queueLimitPerHost: 128), transport: transport,
                authenticator: AppAttestAuthenticator(attester, ifUnsupported: .fail))
            return (attester, client)
        }
    }

    func send(_ request: HTTPRequest, key: IdempotencyKey? = nil) async -> Result<HTTPResponse, any Error> {
        await withTestAmbient(clock: clock, events: events) {
            do { return .success(try await client.send(request, idempotencyKey: key)) } catch { return .failure(error) }
        }
    }
}

@Suite("App Attest: end to end")
struct EndToEndTests {
    @Test func aRequestIsSignedEnrolledVerifiedAndCounted() async throws {
        let app = try await EndToEnd()
        _ = try await app.send(.post("/v1/check-ins?event=e42", json: ["at": "site"]), key: IdempotencyKey(rawValue: "k1")).get()
        let attested = try #require(app.transport.attested.first)
        #expect(attested.path == "/v1/check-ins" && attested.query == "event=e42" && attested.idempotencyKey == "k1")
        #expect(await app.ledger.records.first?.counter.highest == 1)
    }

    @Test(.failureMode("design/29", "many requests arrive while an enrolment is in flight"),
          .failureMode("design/29", "assertions arrive out of order within the window"))
    func aHundredRequestsRaceTheEnrolmentAndEachIsAcceptedOnce() async throws {
        let app = try await EndToEnd()
        let requests = (0..<100).map { index in
            Task { await app.send(.post("/v1/check-ins", json: ["n": .number(JSONNumber(index))]), key: IdempotencyKey(rawValue: "k\(index)")) }
        }
        for request in requests { #expect(try await request.value.get().status == 201) }
        #expect(app.transport.attested.count == 100)
        #expect(await app.ledger.records.count == 1, "one key")
        let counter = try #require(await app.ledger.records.first?.counter)
        #expect(counter.highest >= 100)
    }

    @Test(.failureMode("design/29", "a signed request is retried"))
    func aRetryIsSignedAfreshAndAccepted() async throws {
        let app = try await EndToEnd()
        _ = try await app.send(.post("/v1/check-ins", json: [:])).get()
        app.transport.failNext(1)
        let task = Task { await app.send(.post("/v1/check-ins", json: [:]), key: IdempotencyKey(rawValue: "retried")) }
        // An attempt's own timeout is a sleeper too: wait for the failure first.
        await eventually { app.events.events(named: "retry.attempt_failed").count == 1 && app.clock.sleeperCount == 1 }
        _ = await app.clock.advanceToNextDeadline()
        _ = try await task.value.get()
        #expect(app.transport.attested.count == 2)
    }

    @Test(.failureMode("design/29", "a signed request is redirected within its origin"), .failureMode("design/29", "a signed request is redirected to another origin"))
    func aRedirectIsVerifiedWithinTheOriginAndUnsignedBeyond() async throws {
        let app = try await EndToEnd()
        _ = try await app.send(.post("/v1/a", json: [:]), key: IdempotencyKey(rawValue: "r1")).get()
        #expect(app.transport.attested.map(\.path) == ["/v1/a", "/v1/b"], "each hop verified for its own path")
        let beyond = try #require(app.transport.unsigned.first)
        #expect(beyond.headers["Signature"] == nil && beyond.headers["Idempotency-Key"] == nil)
    }

    @Test(.failureMode("design/29", "a request challenge expires"))
    func anExpiredChallengeIsReplacedBeforeItIsUsed() async throws {
        let app = try await EndToEnd()
        _ = try await app.send(.post("/v1/check-ins", json: [:])).get()
        await app.clock.advance(by: .seconds(301))
        _ = try await app.send(.post("/v1/check-ins", json: [:])).get()
        #expect(app.transport.attested.count == 2)
        #expect(app.events.events(named: "attest.refused").isEmpty, "the client fetched a fresh one itself: no refusal, no replay")
    }

    @Test(.failureMode("design/29", "the server answers unknown_key"))
    func aKeyTheServerForgotIsReplacedTransparently() async throws {
        let app = try await EndToEnd()
        _ = try await app.send(.post("/v1/check-ins", json: [:])).get()
        let first = try #require(await app.ledger.records.first)
        await app.ledger.remove(first.key.id)
        _ = try await app.send(.post("/v1/check-ins", json: [:])).get()
        #expect(await app.ledger.records.count == 1)
        #expect(await app.ledger.records.first?.key.id != first.key.id, "a new key, enrolled")
    }

    @Test(.failureMode("design/29", "the server answers revoked"))
    func aRevokedKeyEndsTheCall() async throws {
        let app = try await EndToEnd()
        _ = try await app.send(.post("/v1/check-ins", json: [:])).get()
        let record = try #require(await app.ledger.records.first)
        _ = await app.ledger.commit(record.revoked(because: "fraud", at: TestClock.wallClockStart), over: record.revision)
        guard case .failure(let error as HTTPError) = await app.send(.post("/v1/check-ins", json: [:])) else {
            Issue.record("a revoked key's request went through")
            return
        }
        #expect(error == .authenticationFailed(AppAttestAuthenticator.error("revoked", .stop), attempts: 1))
    }
}
#endif
