#if STOIC_ATTESTATION
internal import Foundation
public import Stoic

/// The reference composition of the server side (design/29): challenges,
/// enrolment, request verification, the ledger, events.
///
///     let gate = AppAttestGate(app: try AppID("A1B2C3D4E5.app.kindora"), environment: .production,
///                              authority: "api.kindora.app", challenges: challenges, ledger: ledger,
///                              ifUnsupported: .accept)
///
/// Every refusal is an ``AppAttestRefusal`` with a code from design/29's
/// table; ``headers(for:)`` gives the `WWW-Authenticate` and, where the code
/// wants one, a fresh `App-Attest-Challenge`. A ledger that fails is
/// `unavailable` (a 503), never a refusal.
public struct AppAttestGate: Sendable {
    public let app: AppID
    public let environment: AppAttestEnvironment
    public let authority: String
    public let root: AppAttestRoot
    public let challenges: AppAttestChallenges
    public let ledger: any AppAttestLedger
    public let reorderWindow: Int
    public let ifUnsupported: UnsupportedClients

    /// Commits tried against concurrent writers before the gate gives up.
    ///
    /// The writers that contend for one key's record are that one device's
    /// requests in flight, which a client bounds per host (8 by StoicHTTP's
    /// default). After a conflict only the counter is applied again, so the
    /// window between reading and committing is the ledger's round trip; the
    /// bound is twice the client's. More conflicts than this is contention
    /// worth a 503 and a report. (The draft said 3, and re-verified the
    /// signature each time, which refused a client its own parallelism:
    /// found end to end.)
    static let commitAttempts = 16

    /// - Parameters:
    ///   - app: The app id keys must belong to.
    ///   - environment: The environment keys must belong to.
    ///   - authority: The authority the client signs (its URL's host, and port
    ///     when not the scheme's default): the server's own, never the `Host` it received.
    ///   - root: Apple's root; a test's in tests.
    ///   - challenges: The MAC keys and lifetimes.
    ///   - ledger: The app's storage of keys and spent challenges.
    ///   - reorderWindow: 32 by default, at most 63.
    ///   - ifUnsupported: What a client that says it cannot attest may do. No default.
    public init(
        app: AppID, environment: AppAttestEnvironment, authority: String, root: AppAttestRoot = .apple,
        challenges: AppAttestChallenges, ledger: any AppAttestLedger, reorderWindow: Int = 32, ifUnsupported: UnsupportedClients
    ) {
        precondition((0...AssertionCounter.maximumReorderWindow).contains(reorderWindow), "a reorder window is 0 to 63")
        self.app = app
        self.environment = environment
        self.authority = authority
        self.root = root
        self.challenges = challenges
        self.ledger = ledger
        self.reorderWindow = reorderWindow
        self.ifUnsupported = ifUnsupported
    }

    /// A fresh challenge for `purpose`, at the server's moment.
    public func challenge(_ purpose: AppAttestChallengePurpose) -> AppAttestChallenge {
        challenges.issue(purpose, at: .now)
    }

    // MARK: Enrolment

    /// Enrols a key: checks the challenge (fresh, an enrolment one, unspent)
    /// and the attestation, and keeps the key for `account`. Returns the
    /// first request challenge.
    ///
    /// The same enrolment sent again (the same key, attestation and account)
    /// is answered as a success with a new challenge and changes nothing, so
    /// a lost response costs nothing and cannot reset the counter.
    public func enrol(_ enrolment: AppAttestEnrolment, account: String?) async throws(AppAttestRefusal) -> AppAttestChallenge {
        let now = Moment.now
        guard let id = Base64.canonical(enrolment.keyID), id.count == 32 else {
            throw refuseAttestation("invalid_attestation", AttestationFailure.malformed("the key id is not 32 bytes of canonical base64"))
        }
        let digest = AppAttestKeyRecord.digest(of: enrolment.attestation)
        if let existing = try await stored(id) {
            if existing.attestationDigest == digest, existing.account == account { return repeated() }
            throw refuseAttestation("key_enrolled", nil)
        }
        let checked: CheckedChallenge
        do throws(ChallengeRefusal) {
            checked = try challenges.check(enrolment.challenge, for: .enrolment, at: now)
        } catch {
            throw refuseAttestation(error == .expired ? "challenge_expired" : "challenge_invalid", nil, challenge: error)
        }
        let verified: Verified<AttestedKey, KeyAttested>
        do throws(AttestationFailure) {
            verified = try await AppAttest.verifyAttestation(
                enrolment.attestation, keyID: enrolment.keyID, challenge: enrolment.challenge, app: app, environment: environment,
                root: root, at: now)
        } catch {
            let code = if case .environmentMismatch = error { "environment" } else { "invalid_attestation" }
            throw refuseAttestation(code, error)
        }
        guard try await ledgerCall({ try await ledger.spend(challenge: checked.id, until: checked.expires) }) else {
            // Spent by this same enrolment, sent twice at once, is the same enrolment.
            if let existing = try await stored(id), existing.attestationDigest == digest, existing.account == account { return repeated() }
            throw refuseAttestation("challenge_used", nil, challenge: .spent)
        }
        let record = AppAttestKeyRecord(enrolling: verified, account: account, attestation: enrolment.attestation, at: now)
        guard try await ledgerCall({ try await ledger.insert(record) }) else {
            if let existing = try await stored(id), existing.attestationDigest == digest, existing.account == account { return repeated() }
            throw refuseAttestation("key_enrolled", nil)
        }
        AppAttestGateEvents.enrolled(repeated: false)
        return challenge(.requests)
    }

    private func repeated() -> AppAttestChallenge {
        AppAttestGateEvents.enrolled(repeated: true)
        return challenge(.requests)
    }

    private func refuseAttestation(_ code: String, _ failure: AttestationFailure?, challenge: ChallengeRefusal? = nil) -> AppAttestRefusal {
        let cause = failure?.check ?? challenge.map { "challenge_\($0)" } ?? code
        AppAttestGateEvents.attestationRefused(code: code, cause: cause)
        return AppAttestRefusal(code: code, cause: cause, challenge: nil)
    }

    // MARK: Requests

    /// Verifies a signed request: its challenge, its key's record, the
    /// account, the signature and the counter; commits the counter.
    ///
    /// - Parameter account: The account the service authenticated for this
    ///   request, if any. A key enrolled for one account is refused for
    ///   another; a key enrolled anonymously is accepted for any.
    /// - Returns: The attested request, with a fresh challenge when the one it
    ///   used is past half its lifetime; or the client's claim that it cannot
    ///   attest, when ``UnsupportedClients/accept`` lets it through.
    public func verify(_ request: SignedRequest, account: String?) async throws(AppAttestRefusal) -> GateOutcome {
        let now = Moment.now
        let signature: RequestSignature?
        do throws(AssertionFailure) {
            signature = try AppAttest.signature(of: request)
        } catch {
            throw refuseRequest("invalid", cause: error.check)
        }
        guard let signature else { throw refuseRequest("missing", cause: "missing", fresh: true) }
        if let reason = signature.unsupported {
            AppAttestGateEvents.unsupportedClient(reason, accepted: ifUnsupported == .accept)
            guard ifUnsupported == .accept else { throw AppAttestRefusal(code: "unsupported_refused", cause: reason.rawValue, challenge: nil) }
            return .unsupported(Claimed(reason))
        }
        let checked: CheckedChallenge
        do throws(ChallengeRefusal) {
            checked = try challenges.check(signature.nonce, for: .requests, at: now)
        } catch {
            throw refuseRequest("stale_challenge", cause: "challenge_\(error)", fresh: true, level: .debug)
        }
        guard var current = try await stored(signature.keyID) else { throw refuseRequest("unknown_key", cause: "unknown_key") }
        try admit(current, account: account)
        let accepted: AcceptedRequest
        do throws(AssertionFailure) {
            accepted = try AppAttest.verifyRequest(request, authority: authority, record: current, reorderWindow: reorderWindow)
        } catch {
            throw try await refusal(for: error, record: current)
        }
        var next = accepted.record
        for attempt in 1...Self.commitAttempts {
            if try await ledgerCall({ try await ledger.commit(next, over: current.revision) }) {
                let fresh = now >= checked.issued + challenges.requestLifetime / 2 ? challenge(.requests) : nil
                return .attested(accepted.verified, freshChallenge: fresh)
            }
            // Another request of the key committed first. The signature
            // stands (the key never changes); the counter is applied again
            // to the record as it is now, where its bit may well be set.
            AppAttestGateEvents.commitConflict(attempt: attempt, of: Self.commitAttempts)
            guard let reloaded = try await stored(signature.keyID) else { throw refuseRequest("unknown_key", cause: "unknown_key") }
            current = reloaded
            try admit(current, account: account)
            switch current.counter.accepting(accepted.verified.evidence.counter, reorderWindow: reorderWindow) {
            case .success(let counter): next = current.advanced(to: counter)
            case .failure(let failure): throw try await refusal(for: failure, record: current)
            }
        }
        throw AppAttestRefusal(code: "unavailable", cause: "commit_conflict", challenge: nil)
    }

    /// Whether `record` may sign for `account` at all: active, and the
    /// account's own (or enrolled anonymously).
    private func admit(_ record: AppAttestKeyRecord, account: String?) throws(AppAttestRefusal) {
        if case .revoked = record.status { throw refuseRequest("revoked", cause: "revoked") }
        // A key lifted from one account's enrolment is not another's (the review's amendment 3).
        if let owner = record.account, let account, owner != account { throw refuseRequest("account_mismatch", cause: "account") }
    }

    private func refusal(for failure: AssertionFailure, record: AppAttestKeyRecord) async throws(AppAttestRefusal) -> AppAttestRefusal {
        switch failure {
        case .replayed:
            return refuseRequest("replayed", cause: failure.check, fresh: true)
        case .counterRegressed(let counter, let highest):
            // Refused, never revoked: a regression is most often a replay of
            // a captured assertion, and revoking would let that lock out the owner.
            AppAttestGateEvents.counterRegression(distance: Int(highest - counter))
            return refuseRequest("replayed", cause: failure.check, fresh: true)
        case .counterExhausted:
            try await ledgerCall { try await ledger.remove(record.key.id) }
            return refuseRequest("unknown_key", cause: failure.check)
        case .revoked:
            return refuseRequest("revoked", cause: failure.check)
        case .signatureMissing:
            return refuseRequest("missing", cause: failure.check, fresh: true)
        case .malformed, .signatureInvalid, .appIDMismatch, .componentsMissing, .parameter, .bodyDigestMismatch:
            return refuseRequest("invalid", cause: failure.check)
        }
    }

    private func refuseRequest(_ code: String, cause: String, fresh: Bool = false, level: Event.Level = .notice) -> AppAttestRefusal {
        AppAttestGateEvents.assertionRefused(code: code, cause: cause, level: code == "stale_challenge" ? .debug : level)
        return AppAttestRefusal(code: code, cause: cause, challenge: fresh ? challenge(.requests) : nil)
    }

    // MARK: Responses

    /// The headers that go with `refusal`: `WWW-Authenticate: AppAttest
    /// error="<code>"`, and `App-Attest-Challenge` when it carries one.
    public func headers(for refusal: AppAttestRefusal) -> [(name: String, value: String)] {
        var headers: [(name: String, value: String)] = []
        if refusal.status == 401 { headers.append(("WWW-Authenticate", "AppAttest error=\"\(refusal.code)\"")) }
        if let challenge = refusal.challenge { headers.append(Self.challengeHeader(challenge)) }
        return headers
    }

    /// `App-Attest-Challenge: :<base64>:;lifetime=<seconds>`.
    public static func challengeHeader(_ challenge: AppAttestChallenge) -> (name: String, value: String) {
        ("App-Attest-Challenge", ":\(Base64.encode(challenge.bytes)):;lifetime=\(challenge.lifetime.components.seconds)")
    }

    // MARK: The ledger

    private func stored(_ id: [UInt8]) async throws(AppAttestRefusal) -> AppAttestKeyRecord? {
        try await ledgerCall { try await ledger.key(id) }
    }

    /// A ledger call; its failure is the gate's `unavailable`, cancellation included.
    private func ledgerCall<T: Sendable>(_ call: () async throws -> T) async throws(AppAttestRefusal) -> T {
        do {
            return try await call()
        } catch {
            AppAttestGateEvents.ledgerFailed(error)
            throw AppAttestRefusal(code: "unavailable", cause: error is CancellationError ? "cancelled" : "ledger", challenge: nil)
        }
    }
}

/// What a client sends to enrol a key: `{"keyID": "…", "attestation": "…",
/// "challenge": "…"}`, byte strings in standard base64 with padding.
public struct AppAttestEnrolment: Sendable, Hashable, Codable {
    public let keyID: String
    public let attestation: [UInt8]
    public let challenge: [UInt8]

    public init(keyID: String, attestation: [UInt8], challenge: [UInt8]) {
        self.keyID = keyID
        self.attestation = attestation
        self.challenge = challenge
    }

    private enum CodingKeys: String, CodingKey { case keyID, attestation, challenge }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyID = try container.decode(String.self, forKey: .keyID)
        guard let attestation = Base64.canonical(try container.decode(String.self, forKey: .attestation)),
              let challenge = Base64.canonical(try container.decode(String.self, forKey: .challenge)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not canonical base64"))
        }
        self.attestation = attestation
        self.challenge = challenge
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyID, forKey: .keyID)
        try container.encode(Base64.encode(attestation), forKey: .attestation)
        try container.encode(Base64.encode(challenge), forKey: .challenge)
    }
}

/// What the gate made of a request.
public enum GateOutcome: Sendable {
    /// Verified, with a fresh challenge to send back when the one used is
    /// past half its lifetime.
    case attested(Verified<AttestedRequest, AppAttested>, freshChallenge: AppAttestChallenge?)
    /// The client says it cannot attest, and ``UnsupportedClients/accept``
    /// let it through: a claim anyone can make, for the service to decide on.
    case unsupported(Claimed<AppAttestUnsupported>)
}

/// What a client that says it cannot attest may do.
public enum UnsupportedClients: Sendable, Hashable {
    /// Through, as ``GateOutcome/unsupported(_:)``: the service decides.
    case accept
    /// Refused, `unsupported_refused`.
    case refuse
}

/// A refusal, with design/29's code, the check that failed (for logs), and a
/// fresh challenge when the code wants one.
public struct AppAttestRefusal: Error, Sendable, Hashable, Retryable, CustomStringConvertible {
    public let code: String
    public let cause: String
    public let challenge: AppAttestChallenge?

    /// The status to answer with: 422 for an enrolment's refusal, 503 for a
    /// ledger that failed, 401 for a request's.
    public var status: Int {
        switch code {
        case "unavailable": 503
        case "challenge_expired", "challenge_used", "challenge_invalid", "key_enrolled", "invalid_attestation", "environment": 422
        default: 401
        }
    }

    public var retryDecision: RetryDecision { code == "unavailable" ? .retry : .stop }

    public var description: String { "App Attest refused: \(code) (\(cause))" }
}

/// The gate's events (design/29, Events): codes and counts publicly, never a
/// key id, challenge, attestation, assertion or body.
enum AppAttestGateEvents {
    static let label = "app-attest"

    static func enrolled(repeated: Bool) {
        Ambient.record(Event("attest.server_enrolled", level: .info, label: label, fields: [.init("repeated", .bool(repeated))]))
    }

    static func attestationRefused(code: String, cause: String) {
        Ambient.record(Event("attest.attestation_refused", level: .warning, label: label, fields: [
            .init("code", .string(code), privacy: .public),
            .init("check", .string(cause), privacy: .public),
        ]))
    }

    static func assertionRefused(code: String, cause: String, level: Event.Level) {
        Ambient.record(Event("attest.assertion_refused", level: level, label: label, fields: [
            .init("code", .string(code), privacy: .public),
            .init("check", .string(cause), privacy: .public),
        ]))
    }

    static func counterRegression(distance: Int) {
        Ambient.record(Event("attest.counter_regression", level: .warning, label: label, fields: [.init("distance", .int(distance))]))
    }

    static func unsupportedClient(_ reason: AppAttestUnsupported, accepted: Bool) {
        Ambient.record(Event("attest.unsupported_client", level: .info, label: label, fields: [
            .init("reason", .string(reason.rawValue), privacy: .public),
            .init("accepted", .bool(accepted)),
        ]))
    }

    static func commitConflict(attempt: Int, of attempts: Int) {
        Ambient.record(Event("attest.commit_conflict", level: attempt == attempts ? .warning : .notice, label: label, fields: [
            .init("attempt", .int(attempt)),
        ]))
    }

    static func ledgerFailed(_ error: any Error) {
        Ambient.record(Event("attest.ledger_failed", level: .error, label: label, fields: [
            .init("error", .string(String(reflecting: type(of: error))), privacy: .public),
        ]))
    }
}
#endif
