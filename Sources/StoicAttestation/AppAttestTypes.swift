#if STOIC_ATTESTATION
internal import Crypto
internal import Foundation
public import Stoic

/// An app's identity to App Attest: `TEAMID.bundle.id`, the team id (ten
/// upper-case letters and digits), a dot, and the bundle id. Its SHA-256 is
/// the `rpIdHash` in every authenticator data the app's keys produce.
public struct AppID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let teamID: String
    public let bundleID: String

    /// Reads `TEAMID.bundle.id`.
    public init(_ text: String) throws(AppIDError) {
        guard let dot = text.firstIndex(of: ".") else { throw .malformed }
        let team = text[..<dot]
        let bundle = text[text.index(after: dot)...]
        guard team.utf8.count == 10, team.utf8.allSatisfy({ ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x30 && $0 <= 0x39) }) else {
            throw .teamID
        }
        guard !bundle.isEmpty, bundle.utf8.count <= 255,
              bundle.utf8.allSatisfy({ ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2E || $0 == 0x2D }),
              !bundle.hasPrefix("."), !bundle.hasSuffix("."), !bundle.contains("..") else {
            throw .bundleID
        }
        teamID = String(team)
        bundleID = String(bundle)
    }

    /// `TEAMID.bundle.id`.
    public var description: String { "\(teamID).\(bundleID)" }

    /// SHA-256 of the UTF-8 text: the `rpIdHash` App Attest writes.
    public var rpIDHash: [UInt8] { Array(SHA256.hash(data: Array(description.utf8))) }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        do {
            try self.init(text)
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an App ID: \(error)"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Why a text is not an App ID.
public enum AppIDError: Error, Sendable, Hashable {
    /// No dot between a team id and a bundle id.
    case malformed
    /// The team id is not ten upper-case letters and digits.
    case teamID
    /// The bundle id is empty, too long, or not letters, digits, dots and hyphens.
    case bundleID
}

/// Which App Attest environment a key belongs to: the AAGUID in its
/// attestation says, and a key from one is refused by the other.
public enum AppAttestEnvironment: String, Sendable, Hashable, Codable {
    /// `appattestdevelop`: builds run from Xcode.
    case development
    /// `appattest` and seven zero bytes: TestFlight and the App Store.
    case production

    /// The 16-byte AAGUID of this environment.
    var aaguid: [UInt8] {
        switch self {
        case .development: Array("appattestdevelop".utf8)
        case .production: Array("appattest".utf8) + Array(repeating: 0, count: 7)
        }
    }

    init?(aaguid: some Collection<UInt8>) {
        let bytes = Array(aaguid)
        if bytes == Self.development.aaguid { self = .development } else if bytes == Self.production.aaguid { self = .production } else { return nil }
    }
}

/// The root certificate a verifier trusts: Apple's App Attestation Root CA,
/// or a test root.
public struct AppAttestRoot: Sendable, Hashable {
    /// The certificate, DER.
    public let der: [UInt8]
    /// SHA-256 of the DER.
    public let fingerprint: [UInt8]

    /// A root from its DER: a test's (``AppAttestStandIn/root``).
    public init(der: [UInt8]) throws(AttestationFailure) {
        guard !der.isEmpty else { throw .chain("the root certificate is empty") }
        self.der = der
        self.fingerprint = Array(SHA256.hash(data: der))
    }

    private init(trusted der: [UInt8]) {
        self.der = der
        self.fingerprint = Array(SHA256.hash(data: der))
    }

    /// Apple App Attestation Root CA (`CN=Apple App Attestation Root CA,
    /// O=Apple Inc., ST=California`, valid 2020-03-18 to 2045-03-15, P-384),
    /// as published at https://www.apple.com/certificateauthority/. Its
    /// SHA-256 fingerprint, `1CB9823BA28BA6AD2D33A006941DE2AE4F513EF1D4E831B9F7E0FA7B6242C932`,
    /// was the same from two independent downloads (Apple's page, and the
    /// root embedded in an independent verifier) and is pinned by a test.
    public static let apple = AppAttestRoot(trusted: Array(Data(base64Encoded: appleRootDER) ?? Data()))

    private static let appleRootDER = """
        MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYwJAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTET\
        MBEGA1UECgwKQXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNaFw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFw\
        cGxlIEFwcCBBdHRlc3RhdGlvbiBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9ybmlhMHYwEAYHKoZIzj0CAQYFK4EE\
        ACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdhNbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9auYen1mMEvRq9Sk3Jm\
        5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYwCgYI\
        KoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKe\
        YnpqtijVoyFraWVIyd/dganmrduC1bmTBGwD
        """
}

/// What a server keeps from an enrolment: the key Apple certified.
public struct AttestedKey: Sendable, Hashable, Codable {
    /// 32 bytes: the SHA-256 of ``publicKey``, which is the key id.
    public let id: [UInt8]
    /// 65 bytes: the X9.63 uncompressed P-256 point.
    public let publicKey: [UInt8]
    public let app: AppID
    public let environment: AppAttestEnvironment
    /// Apple's receipt, kept for its fraud metric (Not built). Not
    /// authenticated by `verifyAttestation`: it is kept as it arrived, and
    /// whoever uses it verifies Apple's signature on it first.
    public let receipt: [UInt8]
}

/// Why an attestation was refused. Every case is `.stop`: the same bytes
/// will be refused again.
public enum AttestationFailure: Error, Sendable, Hashable, Retryable, CustomStringConvertible {
    /// The object is not the shape design/29 reads: what was wrong.
    case malformed(String)
    /// `fmt` is not `apple-appattest`.
    case format
    /// The certificate chain does not lead to the root at the server's
    /// moment: expired, not yet valid, a bad signature, a constraint.
    case chain(String)
    /// The credential certificate's nonce is not SHA-256(authData ‖ SHA-256(challenge)).
    case nonceMismatch
    /// The key id is not the certified key's hash, or the credential id is not the key id.
    case keyIDMismatch
    /// The rpIdHash is not this app id's.
    case appIDMismatch
    /// The attestation's counter is not zero.
    case counterNotZero
    /// The AAGUID names the other environment, or neither (`nil`).
    case environmentMismatch(found: AppAttestEnvironment?)

    public var retryDecision: RetryDecision { .stop }

    /// A short, stable name for events: which check failed.
    public var check: String {
        switch self {
        case .malformed: "malformed"
        case .format: "format"
        case .chain: "chain"
        case .nonceMismatch: "nonce"
        case .keyIDMismatch: "key_id"
        case .appIDMismatch: "app_id"
        case .counterNotZero: "counter"
        case .environmentMismatch: "environment"
        }
    }

    public var description: String {
        switch self {
        case .malformed(let what): "malformed attestation: \(what)"
        case .chain(let why): "certificate chain refused: \(why)"
        case .environmentMismatch(let found): "environment mismatch (found \(found?.rawValue ?? "neither"))"
        default: "attestation refused: \(check)"
        }
    }
}

/// Why an assertion or a signed request was refused. Every case is `.stop`.
public enum AssertionFailure: Error, Sendable, Hashable, Retryable, CustomStringConvertible {
    /// Not the shape design/29 reads: what was wrong.
    case malformed(String)
    /// The signature does not verify with the record's key over this data.
    case signatureInvalid
    /// The rpIdHash is not the record's app id's.
    case appIDMismatch
    /// The key was revoked.
    case revoked
    /// This counter was accepted before.
    case replayed(counter: UInt32)
    /// The counter is further below the highest accepted than the window.
    case counterRegressed(counter: UInt32, highest: UInt32)
    /// The highest counter accepted is `UInt32.max`: the key can sign no more.
    case counterExhausted
    /// The request has no `attest` signature.
    case signatureMissing
    /// The signature covers fewer components than v1 requires, or others.
    case componentsMissing
    /// A signature parameter is wrong, missing or unexpected: its name.
    case parameter(String)
    /// The body is not the one `Content-Digest` names.
    case bodyDigestMismatch

    public var retryDecision: RetryDecision { .stop }

    /// A short, stable name for events: which check failed.
    public var check: String {
        switch self {
        case .malformed: "malformed"
        case .signatureInvalid: "signature"
        case .appIDMismatch: "app_id"
        case .revoked: "revoked"
        case .replayed: "replayed"
        case .counterRegressed: "counter_regressed"
        case .counterExhausted: "counter_exhausted"
        case .signatureMissing: "missing"
        case .componentsMissing: "components"
        case .parameter: "parameter"
        case .bodyDigestMismatch: "body_digest"
        }
    }

    public var description: String {
        switch self {
        case .malformed(let what): "malformed assertion: \(what)"
        case .replayed(let counter): "counter \(counter) was accepted before"
        case .counterRegressed(let counter, let highest): "counter \(counter) is too far below \(highest)"
        case .parameter(let name): "signature parameter refused: \(name)"
        default: "assertion refused: \(check)"
        }
    }
}
#endif
