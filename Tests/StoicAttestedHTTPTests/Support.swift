#if canImport(DeviceCheck) && canImport(CryptoKit)
import Foundation
import Stoic
@testable import StoicApple
@testable import StoicAttestedHTTP
import StoicHTTP
import StoicJSON
import StoicTesting
import Synchronization
import Testing

extension Trait where Self == ConditionTrait {
    /// Names the design/29 row a test proves, until the contract is committed
    /// and the name becomes a `.failureMode` claim.
    static func designRow(_ row: String) -> Self { .enabled(if: true) }
}

let api = URL(string: "https://api.example.com")!
let phone = AppAttestPlatform(isSimulator: false, isMac: false, isAppExtension: false, isWatch: false)

typealias Sending = Task<HTTPResponse, any Error>

/// An app on a phone: an attester on a scripted device, its enrolment client
/// and the signed client, all over one scripted transport, on a test clock.
final class AttestedRig: Sendable {
    let clock = TestClock()
    let events = RecordingInstrumentation()
    let transport = ScriptedTransport()
    let service: ScriptedAppAttestService
    let store = InMemorySecretStore()
    let attester: AppAttester
    let client: HTTPClient
    let renewals = SendableCounter()

    init(
        signing: AppAttestSigning = .unsafeMethods, ifUnsupported: AppAttestFallback = .declare,
        service: ScriptedAppAttestService = ScriptedAppAttestService(), platform: AppAttestPlatform = phone
    ) async {
        self.service = service
        let (attester, client) = await withTestAmbient(clock: clock, events: events) { [transport, store, renewals] in
            let enrolment = HTTPClient(base: api, transport: transport, label: "app-attest")
            let attester = AppAttester(
                account: "volunteer-7", secrets: store, server: .http(enrolment), service: service,
                policy: AppAttestPolicy(unavailableBackoff: Schedule.exponential(base: .seconds(2)).unjittered().attempts(4)),
                platform: platform)
            let client = HTTPClient(
                base: api, transport: transport, headers: ["Authorization": "Bearer t"],
                reauthenticate: { renewals.increment(); return ["Authorization": "Bearer t2"] },
                authenticator: AppAttestAuthenticator(attester, signing: signing, ifUnsupported: ifUnsupported))
            return (attester, client)
        }
        self.attester = attester
        self.client = client
    }

    /// The enrolment routes, answering as a server that enrols everything.
    func scriptEnrolment(firstChallenge: String? = "AgE=") {
        transport.on(.post("/app-attest/challenge", json: [:]), respond: [], then: .json(#"{"challenge":"AQE=","lifetime":600}"#))
        let enrolled = firstChallenge.map { #"{"challenge":"\#($0)","lifetime":300}"# } ?? "{}"
        transport.on(.post("/app-attest/keys", json: [:]), respond: [], then: .json(enrolled))
    }

    func run<R>(_ body: () async throws -> R) async rethrows -> R {
        try await withTestAmbient(clock: clock, events: events) { () async throws -> R in try await body() }
    }

    func start(_ request: HTTPRequest, key: IdempotencyKey? = nil) -> Sending {
        let client = client
        return Task { try await client.send(request, idempotencyKey: key) }
    }

    func outcome(_ request: HTTPRequest, key: IdempotencyKey? = nil) async -> Result<HTTPResponse, any Error> {
        await run {
            do { return .success(try await client.send(request, idempotencyKey: key)) } catch { return .failure(error) }
        }
    }

    /// The requests the transport saw to `path`.
    func sent(to path: String) -> [HTTPRequest] {
        transport.requests.filter { $0.url?.path == path }
    }
}

final class SendableCounter: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func increment() { count.withLock { $0 += 1 } }
}

/// The parameters of an `attest=(…);keyid="…";nonce="…";alg="…"` signature input.
func signatureParameters(_ request: HTTPRequest) -> (keyID: String, nonce: String)? {
    guard let input = request.headers["Signature-Input"],
          let keyID = AppAttestHeaders.keyID(inSignatureInput: input),
          let start = input.range(of: ";nonce=\"") else { return nil }
    let rest = input[start.upperBound...]
    guard let end = rest.firstIndex(of: "\"") else { return nil }
    return (keyID, String(rest[..<end]))
}

/// The scripted device's assertion inside a request's `Signature` header:
/// `assertion:<n>:<key>:<hash>`.
func assertion(of request: HTTPRequest) -> String? {
    guard let value = request.headers["Signature"], value.hasPrefix("attest=:"), value.hasSuffix(":") else { return nil }
    let encoded = value.dropFirst("attest=:".count).dropLast()
    return Data(base64Encoded: String(encoded)).map { String(decoding: $0, as: UTF8.self) }
}
#endif
