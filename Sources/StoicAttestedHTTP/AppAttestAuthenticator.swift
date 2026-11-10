#if canImport(DeviceCheck) && canImport(CryptoKit)
internal import CryptoKit
internal import Foundation
internal import Stoic
public import StoicApple
public import StoicHTTP
internal import Synchronization

/// App Attest as an `HTTPAuthenticator` (design/29): every request it signs
/// carries an assertion over a statement of its method, authority, path,
/// query, body digest and idempotency key, and a challenge the server issued.
///
///     let client = HTTPClient(base: api, headers: auth,
///                             authenticator: AppAttestAuthenticator(attester, ifUnsupported: .declare))
///
/// - **`prepare`** waits for the attester's enrolled key and holds a request
///   challenge, outside the host's slots.
/// - **`authenticate`** signs each attempt afresh: a new assertion, a new
///   counter, the same idempotency key.
/// - **`received`** reads the server's refusals (`WWW-Authenticate: AppAttest
///   error="…"`) and keeps the freshest `App-Attest-Challenge`: a stale
///   challenge, an unknown key, a replayed counter or a missing signature is
///   repaired and replayed once; a revoked key, an invalid signature or a
///   refused unattested client ends the call.
///
/// What a device that cannot attest does is the app's decision, so
/// `ifUnsupported` has no default.
public final class AppAttestAuthenticator: HTTPAuthenticator {
    private let attester: AppAttester
    private let signing: AppAttestSigning
    private let fallback: AppAttestFallback
    private let clock: AnyClock
    private let state = Mutex(State())
    /// One request-challenge fetch at a time, however many requests find
    /// none: a hundred requests after an enrolment ask the server once.
    private let fetches = SingleFlight<Int, AppAttestChallenge, AppAttestError>(label: "app-attest challenge")

    private struct State {
        /// The request challenge received most recently, and when (monotonic).
        var challenge: (value: AppAttestChallenge, arrived: AnyClock.Instant)?
        /// Requests the server said must be signed (`missing`), whatever `signing` says.
        var forced: Set<Fingerprint> = []
    }

    /// - Parameters:
    ///   - attester: The key that signs.
    ///   - signing: Which requests to sign; `.unsafeMethods` by default.
    ///   - ifUnsupported: What a request does where App Attest cannot run.
    public init(_ attester: AppAttester, signing: AppAttestSigning = .unsafeMethods, ifUnsupported: AppAttestFallback) {
        self.attester = attester
        self.signing = signing
        self.fallback = ifUnsupported
        self.clock = Ambient.current.clock
    }

    static let scheme = "AppAttest"

    static func error(_ code: String, _ decision: RetryDecision) -> HTTPAuthenticationError {
        HTTPAuthenticationError(scheme: scheme, code: code, retryDecision: decision)
    }

    /// The attester's error, as the client reports it.
    static func error(for error: AppAttestError) -> HTTPAuthenticationError {
        Self.error(error.code, error.retryDecision)
    }

    // MARK: HTTPAuthenticator

    public func prepare(_ request: HTTPRequest) async throws(HTTPAuthenticationError) {
        guard wantsSignature(request) else { return }
        if case .unsupported = attester.availability {
            if fallback == .fail { throw Self.error("unsupported", .stop) }
            return
        }
        do throws(AppAttestError) {
            _ = try await attester.enrolledKey()
            if heldChallenge() == nil { try await fetchChallenge() }
        } catch {
            if case .unsupported = error, fallback == .declare { return }
            throw Self.error(for: error)
        }
    }

    public func authenticate(_ request: HTTPRequest) async throws(HTTPAuthenticationError) -> HTTPHeaders {
        guard wantsSignature(request) else { return [:] }
        if request.headers.contains("Signature") || request.headers.contains("Signature-Input") {
            throw Self.error("header_conflict", .stop)
        }
        if case .unsupported(let reason) = attester.availability { return try declare(reason) }
        let statement = try Statement(request)
        var key: AppAttestKeyID
        do throws(AppAttestError) {
            key = try await attester.enrolledKey()
        } catch {
            if case .unsupported(let reason) = error { return try declare(reason) }
            throw Self.error(for: error)
        }
        guard let nonce = heldChallenge()?.bytes ?? state.withLock({ $0.challenge?.value.bytes }) else {
            throw Self.error("no_challenge", .retry)
        }
        // A key the device lost is replaced, and the statement (which names
        // the key) rebuilt and signed once more; a second loss is final.
        var replaced = false
        while true {
            let base = statement.base(keyID: key.base64, nonce: nonce)
            do throws(AppAttestError) {
                let assertion = try await attester.assertion(over: AppAttestRequestFormat.clientDataHash(of: base), with: key)
                return [
                    "Content-Digest": statement.contentDigest,
                    "Signature-Input": "\(AppAttestRequestFormat.label)="
                        + AppAttestRequestFormat.signatureParameters(keyID: key.base64, nonce: nonce, idempotencyKey: statement.idempotencyKey != nil),
                    "Signature": "\(AppAttestRequestFormat.label)=:\(Data(assertion).base64EncodedString()):",
                ]
            } catch {
                guard error == .keyInvalidated, !replaced else { throw Self.error(for: error) }
                replaced = true
                do throws(AppAttestError) {
                    key = try await attester.enrolledKey()
                } catch {
                    throw Self.error(for: error)
                }
            }
        }
    }

    public func received(_ response: HTTPResponse, to request: HTTPRequest) async -> HTTPAuthenticatorVerdict {
        let fresh = response.headers["App-Attest-Challenge"].flatMap(AppAttestHeaders.challenge)
        if let fresh { keep(fresh) }
        let fingerprint = Fingerprint(request)
        if request.headers.contains("Signature") { _ = state.withLock { $0.forced.remove(fingerprint) } }
        guard response.status == 401, let code = AppAttestHeaders.errorCode(response.headers.values(for: "WWW-Authenticate")) else {
            return .accept
        }
        let verdict: HTTPAuthenticatorVerdict
        switch code {
        case "missing":
            state.withLock { _ = $0.forced.insert(fingerprint) }
            verdict = .replay
        case "stale_challenge":
            if fresh == nil { state.withLock { $0.challenge = nil } }
            verdict = .replay
        case "replayed":
            verdict = .replay
        case "unknown_key":
            verdict = await forget(request, revoked: false) ?? .replay
        case "revoked":
            verdict = await forget(request, revoked: true) ?? .refuse(Self.error("revoked", .stop))
        case "invalid", "unsupported_refused", "account_mismatch":
            verdict = .refuse(Self.error(code, .stop))
        default:
            // A code this version does not know is not trusted to mean
            // anything milder than its own refusal.
            verdict = .refuse(Self.error("invalid", .stop))
        }
        Ambient.record(Event("attest.refused", level: .info, label: "app-attest", fields: [
            .init("code", .string(AppAttestHeaders.knownCodes.contains(code) ? code : "unknown"), privacy: .public),
            .init("replayed", .bool(verdict == .replay)),
        ]))
        return verdict
    }

    // MARK: What to sign

    private func wantsSignature(_ request: HTTPRequest) -> Bool {
        if state.withLock({ $0.forced.contains(Fingerprint(request)) }) { return true }
        switch signing {
        case .unsafeMethods: return [.post, .put, .patch, .delete].contains(request.method)
        case .every: return true
        case .matching(let predicate): return predicate(request)
        }
    }

    private func declare(_ reason: AppAttestUnsupported) throws(HTTPAuthenticationError) -> HTTPHeaders {
        switch fallback {
        case .declare: return ["App-Attest": "unsupported;reason=\(reason.rawValue)"]
        case .fail: throw Self.error("unsupported", .stop)
        }
    }

    /// The challenge held, if its lifetime has not passed by the monotonic
    /// clock since it arrived.
    private func heldChallenge() -> AppAttestChallenge? {
        state.withLock { state in
            guard let held = state.challenge, clock.now < held.arrived.advanced(by: held.value.lifetime) else { return nil }
            return held.value
        }
    }

    private func keep(_ challenge: AppAttestChallenge) {
        let now = clock.now
        state.withLock { $0.challenge = (challenge, now) }
    }

    /// Fetches a request challenge, sharing the fetch in flight; the one that
    /// arrives is kept for every request.
    private func fetchChallenge() async throws(AppAttestError) {
        let attester = attester
        do throws(PolicyError<AppAttestError>) {
            let fresh = try await fetches.run(0) { () async throws(AppAttestError) -> AppAttestChallenge in
                try await attester.requestChallenge()
            }
            keep(fresh)
        } catch {
            switch error {
            case .failed(let failure): throw failure
            case .rejected(let rejection): throw rejection.reason == .cancelled ? .cancelled : .timedOut
            }
        }
    }

    /// Forgets the key that signed `request`: `nil` when that went well, or
    /// the refusal when the attester could not.
    private func forget(_ request: HTTPRequest, revoked: Bool) async -> HTTPAuthenticatorVerdict? {
        guard let keyID = AppAttestHeaders.keyID(inSignatureInput: request.headers["Signature-Input"]) else { return nil }
        let key = AppAttestKeyID(base64: keyID)
        do throws(AppAttestError) {
            if revoked { try await attester.revoked(key) } else { try await attester.discard(key, because: "unknown_key") }
            return nil
        } catch {
            return .refuse(Self.error(for: error))
        }
    }
}

/// Which requests an ``AppAttestAuthenticator`` signs.
public enum AppAttestSigning: Sendable {
    /// `POST`, `PUT`, `PATCH` and `DELETE`: a change is what a server must
    /// attribute. The default.
    case unsafeMethods
    /// Every request to the base URL's origin.
    case every
    /// The requests `predicate` chooses.
    case matching(@Sendable (HTTPRequest) -> Bool)
}

/// What a request does where App Attest cannot run.
public enum AppAttestFallback: Sendable, Hashable {
    /// Sends `App-Attest: unsupported;reason=…` and no signature: the server
    /// sees a claim and decides.
    case declare
    /// Sends nothing: `HTTPError.authenticationFailed` with code
    /// `unsupported`, `.stop`.
    case fail
}

/// What identifies a request, so the server's `missing` can make that one
/// request signed on its replay.
struct Fingerprint: Hashable, Sendable {
    let method: String
    let url: String
    let body: [UInt8]

    init(_ request: HTTPRequest) {
        method = request.method.rawValue
        url = request.url?.absoluteString ?? ""
        body = Array(SHA256.hash(data: request.body ?? []))
    }
}

/// The parts of a request the statement covers.
struct Statement {
    let method: String
    let authority: String
    let path: String
    let query: String
    let contentDigest: String
    let idempotencyKey: String?

    init(_ request: HTTPRequest) throws(HTTPAuthenticationError) {
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(), let scheme = components.scheme?.lowercased() else {
            throw AppAttestAuthenticator.error("unsignable", .stop)
        }
        let defaultPort = scheme == "https" ? 443 : scheme == "http" ? 80 : nil
        method = request.method.rawValue.uppercased()
        authority = components.port.map { $0 == defaultPort ? host : "\(host):\($0)" } ?? host
        path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        query = components.percentEncodedQuery ?? ""
        contentDigest = AppAttestRequestFormat.contentDigest(of: request.body ?? [])
        idempotencyKey = request.headers[HTTPRequest.idempotencyKeyHeader]
        for value in [method, authority, path, query, idempotencyKey ?? ""] where !AppAttestRequestFormat.isSignable(value) {
            throw AppAttestAuthenticator.error("unsignable", .stop)
        }
    }

    func base(keyID: String, nonce: [UInt8]) -> String {
        AppAttestRequestFormat.signatureBase(
            method: method, authority: authority, path: path, query: query, contentDigest: contentDigest,
            idempotencyKey: idempotencyKey, keyID: keyID, nonce: nonce)
    }
}

/// The few header values the client reads, parsed strictly: anything off
/// the shape is ignored, never guessed at.
enum AppAttestHeaders {
    /// The codes design/29's table defines for requests and enrolments.
    static let knownCodes: Set<String> = [
        "challenge_expired", "challenge_used", "challenge_invalid", "key_enrolled", "invalid_attestation", "environment",
        "missing", "stale_challenge", "unknown_key", "revoked", "replayed", "invalid", "unsupported_refused", "account_mismatch",
    ]

    /// `App-Attest-Challenge: :<base64>:;lifetime=<seconds>` (an RFC 8941
    /// byte sequence with one integer parameter).
    static func challenge(_ value: String) -> AppAttestChallenge? {
        let text = value.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix(":") else { return nil }
        let rest = text.dropFirst()
        guard let close = rest.firstIndex(of: ":") else { return nil }
        let encoded = rest[..<close]
        let parameters = rest[rest.index(after: close)...]
        guard encoded.utf8.allSatisfy(isBase64), let bytes = Data(base64Encoded: String(encoded)), !bytes.isEmpty,
              parameters.hasPrefix(";lifetime=") else { return nil }
        let digits = parameters.dropFirst(";lifetime=".count)
        guard (1...15).contains(digits.count), digits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              let seconds = Int64(digits), seconds > 0 else { return nil }
        return AppAttestChallenge(bytes: Array(bytes), lifetime: .seconds(seconds))
    }

    /// The code of an `AppAttest error="<code>"` challenge among
    /// `WWW-Authenticate` values, if there is exactly one such code.
    static func errorCode(_ values: [String]) -> String? {
        var found: [String] = []
        for value in values {
            for challenge in value.split(separator: ",") {
                let part = challenge.trimmingCharacters(in: .whitespaces)
                guard part.lowercased().hasPrefix("appattest ") else { continue }
                let parameter = part.dropFirst("appattest ".count).trimmingCharacters(in: .whitespaces)
                guard parameter.hasPrefix("error=\""), parameter.hasSuffix("\""), parameter.count > "error=\"\"".count else { return nil }
                let code = parameter.dropFirst("error=\"".count).dropLast()
                guard code.count <= 64, code.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F }) else { return nil }
                found.append(String(code))
            }
        }
        return found.count == 1 ? found[0] : nil
    }

    /// The `keyid` parameter of an `attest=` signature input.
    static func keyID(inSignatureInput value: String?) -> String? {
        guard let value, let start = value.range(of: ";keyid=\"") else { return nil }
        let rest = value[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private static func isBase64(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
            || byte == 0x2B || byte == 0x2F || byte == 0x3D
    }
}
#endif
