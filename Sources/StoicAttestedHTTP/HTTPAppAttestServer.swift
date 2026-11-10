#if canImport(DeviceCheck) && canImport(CryptoKit)
internal import Foundation
internal import Stoic
public import StoicApple
public import StoicHTTP
internal import StoicJSON

/// The app's server, over HTTP, as design/29's wire protocol has it: what an
/// `AppAttester` asks for a challenge and an enrolment.
///
/// | Exchange | Request | Success | Refusal |
/// | --- | --- | --- | --- |
/// | `POST <challengePath>` | `{"purpose": "enrolment" or "requests"}` | `200 {"challenge": "…", "lifetime": 600}` | — |
/// | `POST <keysPath>`, keyed `app-attest:<key id>` | `{"keyID": "…", "attestation": "…", "challenge": "…"}` | `200 {"challenge": "…", "lifetime": 300}` | `422 {"error": "<code>"}` |
///
/// Byte strings are standard base64 with padding, lifetimes are seconds. The
/// client must not be the one the authenticator signs for: a request sent
/// through it would wait for the enrolment it is part of. Its calls skip any
/// authenticator all the same (`HTTPOverrides.authenticate`).
public struct HTTPAppAttestServer: AppAttestServer {
    public let client: HTTPClient
    public let challengePath: String
    public let keysPath: String

    public init(client: HTTPClient, challengePath: String = "/app-attest/challenge", keysPath: String = "/app-attest/keys") {
        self.client = client
        self.challengePath = challengePath
        self.keysPath = keysPath
    }

    public func challenge(for purpose: AppAttestChallengePurpose) async throws(AppAttestServerError) -> AppAttestChallenge {
        let response = try await send(.post(challengePath, json: ["purpose": .string(purpose.rawValue)]), key: nil)
        guard let challenge = Self.challenge(in: response.body) else { throw .unreachable(.stop, neverReachedBackend: false) }
        return challenge
    }

    public func enrol(_ key: AppAttestKeyID, attestation: [UInt8], challenge: AppAttestChallenge)
        async throws(AppAttestServerError) -> AppAttestChallenge?
    {
        let body: JSONValue = [
            "keyID": .string(key.base64),
            "attestation": .string(Data(attestation).base64EncodedString()),
            "challenge": .string(Data(challenge.bytes).base64EncodedString()),
        ]
        // Keyed by the key: the same enrolment, sent again after a lost
        // response, is retried by the client and recognised by the server.
        let response = try await send(.post(keysPath, json: body), key: IdempotencyKey(rawValue: "app-attest:\(key.base64)"))
        return Self.challenge(in: response.body)
    }

    private func send(_ request: HTTPRequest, key: IdempotencyKey?) async throws(AppAttestServerError) -> HTTPResponse {
        do {
            return try await client.send(request, idempotencyKey: key, overrides: HTTPOverrides(authenticate: false))
        } catch let error as HTTPError {
            if case .status(422, let excerpt, _, _, _) = error {
                throw .refused(code: Self.refusalCode(in: excerpt))
            }
            throw .unreachable(error.retryDecision, neverReachedBackend: error.neverReachedBackend)
        } catch {
            // Cancellation: the enrolment's own timeout. Whether it was sent is unknown.
            throw .unreachable(error is CancellationError ? .stop : .retry, neverReachedBackend: false)
        }
    }

    /// `{"challenge": "<base64>", "lifetime": <seconds>}`, or `nil`.
    static func challenge(in body: [UInt8]) -> AppAttestChallenge? {
        guard let object = object(in: body), let text = object["challenge"]?.string, let bytes = Data(base64Encoded: text), !bytes.isEmpty,
              let seconds = object["lifetime"]?.number?.integralInt64, seconds > 0 else { return nil }
        return AppAttestChallenge(bytes: Array(bytes), lifetime: .seconds(seconds))
    }

    /// The code of a `422 {"error": "<code>"}`, as the start of the body the
    /// client kept; one that is not a known code is `invalid`.
    static func refusalCode(in excerpt: String) -> String {
        guard let object = object(in: Array(excerpt.utf8)), let code = object["error"]?.string, AppAttestHeaders.knownCodes.contains(code) else { return "invalid" }
        return code
    }
}

extension HTTPAppAttestServer {
    /// The JSON object `bytes` hold, or `nil`: a body that is not one is no
    /// answer of this protocol.
    static func object(in bytes: [UInt8]) -> JSONObject? {
        do {
            return try JSONValue(parsing: bytes).object
        } catch {
            return nil
        }
    }
}

extension AppAttestServer where Self == HTTPAppAttestServer {
    /// design/29's wire protocol over `client`, which must not be the client
    /// the authenticator signs for.
    public static func http(
        _ client: HTTPClient, challengePath: String = "/app-attest/challenge", keysPath: String = "/app-attest/keys"
    ) -> HTTPAppAttestServer {
        HTTPAppAttestServer(client: client, challengePath: challengePath, keysPath: keysPath)
    }
}
#endif
