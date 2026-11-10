#if STOIC_ATTESTATION
internal import Crypto
internal import Foundation
public import Stoic
internal import SwiftASN1
// The fixed validation time is the server's moment, passed in, never the
// machine's "now" read behind its back: swift-certificates offers that only
// as SPI (its public initialiser for it is deprecated).
@_spi(FixedExpiryValidationTime) internal import X509

/// Evidence that Apple certified a key for an app id and environment, for a
/// challenge (design/29). Not content evidence: it says nothing about any
/// request the key signs later.
public struct KeyAttested: Evidence, Hashable {
    /// Constructible only in AppAttest.swift, by `verifyAttestation`.
    public struct Mint: Sendable {
        fileprivate init() {}
    }

    public static let proves = "Apple certified this key for this app id and environment, for this challenge"

    /// The fingerprint of the root the chain led to.
    public let root: [UInt8]
    /// The server's moment the chain was valid at.
    public let verifiedAt: Moment

    fileprivate init(root: [UInt8], verifiedAt: Moment) {
        self.root = root
        self.verifiedAt = verifiedAt
    }
}

/// Evidence that a request or its bytes were signed by an App Attest key
/// Apple certified for an unmodified instance of this app on genuine
/// hardware, are unaltered, and carry a counter not used before (design/29).
///
/// Content evidence, and not principal evidence: it says which app and
/// device key sent the bytes, never who the user is, and never that what
/// they say is true. A function that needs an authenticated person refuses
/// it at compile time.
public struct AppAttested: ContentEvidence, Hashable {
    /// Constructible only in AppAttest.swift, by the verifier.
    public struct Mint: Sendable {
        fileprivate init() {}
    }

    public static let proves =
        "signed by an App Attest key Apple certified for an unmodified instance of this app on genuine hardware; unaltered; its counter is new"

    /// The key id (32 bytes).
    public let key: [UInt8]
    public let app: AppID
    public let environment: AppAttestEnvironment
    /// The assertion's counter.
    public let counter: UInt32
    /// The account the key was enrolled for, if any.
    public let account: String?

    fileprivate init(key: [UInt8], app: AppID, environment: AppAttestEnvironment, counter: UInt32, account: String?) {
        self.key = key
        self.app = app
        self.environment = environment
        self.counter = counter
        self.account = account
    }
}

/// The verifier's authority, private to this file.
private let keyMinter = Minter<KeyAttested>(KeyAttested.Mint())
private let requestMinter = Minter<AppAttested>(AppAttested.Mint())

/// The server's App Attest checks (design/29): pure functions of bytes, the
/// server's moment and the key's record. They record nothing; the gate
/// (``AppAttestGate``) composes them with challenges, a ledger and events.
public enum AppAttest {
    /// The credential certificate's extension holding the nonce.
    static let nonceExtension: ASN1ObjectIdentifier = [1, 2, 840, 113_635, 100, 8, 2]

    /// Apple's attestation checks, in Apple's order (design/29, Verifying an
    /// attestation). The first that fails is the error.
    ///
    /// The challenge's freshness and single use are the caller's to check
    /// first (the gate does). The chain is validated by swift-certificates at
    /// `now`, the server's moment, never the client's.
    ///
    /// - Parameters:
    ///   - object: The attestation object, as `attestKey` returned it.
    ///   - keyID: The key id, as `generateKey` returned it (base64).
    ///   - challenge: The bytes whose SHA-256 the client attested over.
    ///   - app: The app id the key must belong to.
    ///   - environment: The environment the key must belong to.
    ///   - root: Apple's root, or a test's.
    ///   - now: The server's moment.
    public static func verifyAttestation(
        _ object: [UInt8], keyID: String, challenge: [UInt8], app: AppID, environment: AppAttestEnvironment,
        root: AppAttestRoot = .apple, at now: Moment
    ) async throws(AttestationFailure) -> Verified<AttestedKey, KeyAttested> {
        // 1. Decode: {fmt, attStmt: {x5c, receipt}, authData}, and nothing else.
        let decoded: CBORValue
        do throws(CBORFailure) {
            decoded = try CBORReader.read(object)
        } catch {
            throw .malformed(error.reason)
        }
        guard let map = decoded.map, map.keys == ["fmt", "attStmt", "authData"] else { throw .malformed("not a map of fmt, attStmt and authData") }
        guard let format = map["fmt"]?.text else { throw .malformed("fmt is not text") }
        guard let statement = map["attStmt"]?.map, statement.keys == ["x5c", "receipt"] else { throw .malformed("attStmt is not a map of x5c and receipt") }
        guard let chain = statement["x5c"]?.array, let receipt = statement["receipt"]?.bytes else { throw .malformed("x5c or receipt of the wrong type") }
        guard let authData = map["authData"]?.bytes else { throw .malformed("authData is not a byte string") }
        guard format == "apple-appattest" else { throw .format }

        // 2. The chain: credential certificate, intermediate, root.
        guard chain.count == 2, let credentialDER = chain[0].bytes, let intermediateDER = chain[1].bytes else {
            throw .malformed("x5c is not two certificates")
        }
        let credential: Certificate
        let intermediate: Certificate
        let anchor: Certificate
        do {
            credential = try Certificate(derEncoded: credentialDER)
            intermediate = try Certificate(derEncoded: intermediateDER)
        } catch {
            throw .malformed("a certificate in x5c does not decode")
        }
        do {
            anchor = try Certificate(derEncoded: root.der)
        } catch {
            throw .chain("the root certificate does not decode")
        }
        var verifier = Verifier(rootCertificates: CertificateStore([anchor])) {
            RFC5280Policy(fixedExpiryValidationTime: date(of: now))
            CredentialCertificatePolicy()
        }
        switch await verifier.validate(leaf: credential, intermediates: CertificateStore([intermediate])) {
        case .validCertificate(let validated):
            guard Array(validated) == [credential, intermediate, anchor] else { throw .chain("the chain is not credential, intermediate, root") }
        case .couldNotValidate(let failures):
            throw .chain(failures.first.map { String(describing: $0.policyFailureReason) } ?? "no chain to the root")
        }

        // 3. The nonce: SHA-256(authData ‖ SHA-256(challenge)), in the certified extension.
        let clientDataHash = Array(SHA256.hash(data: challenge))
        let nonce = Array(SHA256.hash(data: authData + clientDataHash))
        guard let certified = credential.extensions[oid: nonceExtension] else { throw .malformed("no nonce extension") }
        guard let found = nonceInExtension(certified.value) else { throw .malformed("the nonce extension is not SEQUENCE { [1] OCTET STRING (32) }") }
        guard found == nonce else { throw .nonceMismatch }

        // 4. The key: SHA-256 of the certified P-256 key is the key id.
        guard let publicKey = P256.Signing.PublicKey(credential.publicKey) else { throw .malformed("the credential key is not P-256") }
        let point = Array(publicKey.x963Representation)
        guard let id = Base64.canonical(keyID), id.count == 32 else { throw .malformed("the key id is not 32 bytes of canonical base64") }
        guard Array(SHA256.hash(data: point)) == id else { throw .keyIDMismatch }

        // 5. The authenticator data: rpIdHash, flags, counter, AAGUID, credential id.
        guard authData.count >= 87 else { throw .malformed("authData shorter than 87 bytes") }
        guard Array(authData[0..<32]) == app.rpIDHash else { throw .appIDMismatch }
        guard authData[33..<37].allSatisfy({ $0 == 0 }) else { throw .counterNotZero }
        guard authData[53] == 0, authData[54] == 32 else { throw .malformed("the credential id is not 32 bytes") }
        guard Array(authData[55..<87]) == id else { throw .keyIDMismatch }

        // 6. The environment, from the AAGUID.
        let found6 = AppAttestEnvironment(aaguid: authData[37..<53])
        guard found6 == environment else { throw .environmentMismatch(found: found6) }

        let key = AttestedKey(id: id, publicKey: point, app: app, environment: environment, receipt: receipt)
        return keyMinter.verified(key, KeyAttested(root: root.fingerprint, verifiedAt: now))
    }

    /// Apple's assertion checks, and the counter window (design/29,
    /// Verifying an assertion). Pure: the caller commits the returned record
    /// over the old revision, and nothing is accepted until it does.
    ///
    /// - Parameters:
    ///   - assertion: The assertion object, as `generateAssertion` returned it.
    ///   - clientData: The bytes whose SHA-256 the client asserted over.
    ///   - record: The key's record.
    ///   - reorderWindow: How far below the highest counter one may arrive (0 to 63).
    public static func verifyAssertion(
        _ assertion: [UInt8], over clientData: [UInt8], record: AppAttestKeyRecord, reorderWindow: Int = 32
    ) throws(AssertionFailure) -> AcceptedAssertion {
        // 1. Decode: {signature, authenticatorData}, and nothing else; 37 bytes of data.
        let decoded: CBORValue
        do throws(CBORFailure) {
            decoded = try CBORReader.read(assertion)
        } catch {
            throw .malformed(error.reason)
        }
        guard let map = decoded.map, map.keys == ["signature", "authenticatorData"],
              let signatureDER = map["signature"]?.bytes, let authenticatorData = map["authenticatorData"]?.bytes else {
            throw .malformed("not a map of signature and authenticatorData")
        }
        guard authenticatorData.count == 37 else { throw .malformed("authenticatorData is not 37 bytes") }

        // 2. The signature: ECDSA P-256 with SHA-256 over the nonce, so the
        //    nonce is hashed once more by the scheme.
        let nonce = Array(SHA256.hash(data: authenticatorData + Array(SHA256.hash(data: clientData))))
        let key: P256.Signing.PublicKey
        let signature: P256.Signing.ECDSASignature
        do {
            key = try P256.Signing.PublicKey(x963Representation: record.key.publicKey)
        } catch {
            throw .malformed("the record's key is not a P-256 point")
        }
        do {
            signature = try P256.Signing.ECDSASignature(derRepresentation: signatureDER)
        } catch {
            throw .malformed("the signature is not DER ECDSA")
        }
        guard key.isValidSignature(signature, for: nonce) else { throw .signatureInvalid }

        // 3. The app, 4. the record, 5. the counter.
        guard Array(authenticatorData[0..<32]) == record.key.app.rpIDHash else { throw .appIDMismatch }
        guard case .active = record.status else { throw .revoked }
        var counter: UInt32 = 0
        for byte in authenticatorData[33..<37] { counter = counter << 8 | UInt32(byte) }
        let advanced: AssertionCounter
        switch record.counter.accepting(counter, reorderWindow: reorderWindow) {
        case .success(let accepted): advanced = accepted
        case .failure(let failure): throw failure
        }
        let evidence = AppAttested(
            key: record.key.id, app: record.key.app, environment: record.key.environment, counter: counter, account: record.account)
        return AcceptedAssertion(verified: requestMinter.verified(clientData, evidence), record: record.advanced(to: advanced))
    }

    /// The key id and challenge a request names, to look them up; or that it
    /// says it cannot attest. Parses; verifies nothing. `nil` when the request
    /// carries neither a signature nor a declaration.
    public static func signature(of request: SignedRequest) throws(AssertionFailure) -> RequestSignature? {
        let declared = try declaration(of: request)
        guard let parsed = try parse(request) else {
            return declared.map { RequestSignature(keyID: [], nonce: [], unsupported: $0) }
        }
        guard declared == nil else { throw .parameter("app-attest") }
        return RequestSignature(keyID: parsed.keyID, nonce: parsed.nonce, unsupported: nil)
    }

    /// A request: its components, the body's digest, the assertion and the
    /// counter (design/29, Verifying a request). Pure, as
    /// ``verifyAssertion(_:over:record:reorderWindow:)``.
    ///
    /// - Parameters:
    ///   - request: What the server received.
    ///   - authority: The server's configured authority, never the `Host`
    ///     it received.
    ///   - record: The record of the key the signature names.
    ///   - reorderWindow: As for an assertion.
    public static func verifyRequest(
        _ request: SignedRequest, authority: String, record: AppAttestKeyRecord, reorderWindow: Int = 32
    ) throws(AssertionFailure) -> AcceptedRequest {
        guard let parsed = try parse(request) else { throw .signatureMissing }
        guard parsed.keyID == record.key.id else { throw .parameter("keyid") }
        // The body, by its digest: exactly one sha-256 member.
        guard let digestValue = try single(request, "content-digest") else { throw .malformed("no Content-Digest") }
        let digest: SFDictionary
        do throws(SFFailure) {
            digest = try SFParser.dictionary(digestValue)
        } catch {
            throw .malformed("Content-Digest: \(error.reason)")
        }
        guard digest.entries.count == 1, case .item(.bytes(let claimed), let parameters)? = digest["sha-256"], parameters.isEmpty,
              claimed.count == 32 else {
            throw .malformed("Content-Digest is not one sha-256 member")
        }
        guard claimed == Array(SHA256.hash(data: request.body)) else { throw .bodyDigestMismatch }
        let idempotencyKey = try single(request, "idempotency-key")
        let base = signatureBase(
            method: request.method, authority: authority, path: request.path, query: request.query, contentDigest: digestValue,
            idempotencyKey: idempotencyKey, parameters: parsed.parameters)
        let accepted = try verifyAssertion(parsed.assertion, over: Array(base.utf8), record: record, reorderWindow: reorderWindow)
        let attested = AttestedRequest(
            method: request.method, authority: authority, path: request.path.isEmpty ? "/" : request.path, query: request.query,
            idempotencyKey: idempotencyKey, body: request.body)
        return AcceptedRequest(verified: requestMinter.verified(attested, accepted.verified.evidence), record: accepted.record)
    }

    // MARK: Parsing a request

    /// The parts of an `attest` signature.
    struct Parsed {
        let keyID: [UInt8]
        let nonce: [UInt8]
        let assertion: [UInt8]
        /// The `@signature-params` value, rebuilt from what was parsed.
        let parameters: String
    }

    /// The `attest` signature, or `nil` when the request has neither header's
    /// `attest` member.
    static func parse(_ request: SignedRequest) throws(AssertionFailure) -> Parsed? {
        let inputValue = request.combined("signature-input")
        let signatureValue = request.combined("signature")
        guard inputValue != nil || signatureValue != nil else { return nil }
        let inputs: SFDictionary
        let signatures: SFDictionary
        do throws(SFFailure) {
            inputs = try SFParser.dictionary(inputValue ?? "")
            signatures = try SFParser.dictionary(signatureValue ?? "")
        } catch {
            throw .malformed("Signature-Input or Signature: \(error.reason)")
        }
        guard let input = inputs["attest"], let signature = signatures["attest"] else {
            if inputs["attest"] == nil, signatures["attest"] == nil { return nil }
            throw .signatureMissing
        }
        guard case .item(.bytes(let assertion), let signatureParameters) = signature, signatureParameters.isEmpty else {
            throw .malformed("the attest signature is not a byte sequence")
        }
        guard case .innerList(let items, let parameters) = input else { throw .malformed("the attest input is not an inner list") }
        var components: [String] = []
        for item in items {
            guard case .string(let name) = item.item, item.parameters.isEmpty else { throw .malformed("a component that is not a plain string") }
            components.append(name)
        }
        let keyed = request.has("idempotency-key")
        let required = ["@method", "@authority", "@path", "@query", "content-digest"] + (keyed ? ["idempotency-key"] : [])
        guard Set(required).isSubset(of: Set(components)) else { throw .componentsMissing }
        guard components == required else { throw .parameter("components") }
        let names = parameters.entries.map(\.key)
        for name in names where !["keyid", "nonce", "alg"].contains(name) { throw .parameter(name) }
        guard names == ["keyid", "nonce", "alg"] else {
            throw .parameter(["keyid", "nonce", "alg"].first { !names.contains($0) } ?? "order")
        }
        guard parameters["alg"]?.string == "apple-app-attest" else { throw .parameter("alg") }
        guard let keyIDText = parameters["keyid"]?.string, let keyID = Base64.canonical(keyIDText), keyID.count == 32 else {
            throw .parameter("keyid")
        }
        guard let nonceText = parameters["nonce"]?.string, let nonce = Base64.canonical(nonceText), (1...64).contains(nonce.count) else {
            throw .parameter("nonce")
        }
        let serialized = "(" + components.map { "\"\($0)\"" }.joined(separator: " ") + ")"
            + ";keyid=\"\(keyIDText)\";nonce=\"\(nonceText)\";alg=\"apple-app-attest\""
        return Parsed(keyID: keyID, nonce: nonce, assertion: assertion, parameters: serialized)
    }

    /// `App-Attest: unsupported;reason=<token>`, or `nil` without the header.
    static func declaration(of request: SignedRequest) throws(AssertionFailure) -> AppAttestUnsupported? {
        guard let value = try single(request, "app-attest") else { return nil }
        let parsed: (SFItem, SFParameters)
        do throws(SFFailure) {
            parsed = try SFParser.item(value)
        } catch {
            throw .malformed("App-Attest: \(error.reason)")
        }
        guard parsed.0 == .token("unsupported"), parsed.1.entries.count == 1, let reason = parsed.1["reason"]?.token,
              let unsupported = AppAttestUnsupported(rawValue: reason) else {
            throw .parameter("app-attest")
        }
        return unsupported
    }

    /// The one value of header `name`: `nil` without it, refused when it repeats.
    private static func single(_ request: SignedRequest, _ name: String) throws(AssertionFailure) -> String? {
        let values = request.values(name)
        guard values.count <= 1 else { throw .malformed("\(name) appears more than once") }
        return values.first
    }

    /// The base, as format v1 builds it (`AppAttestRequestFormat` on the client).
    static func signatureBase(
        method: String, authority: String, path: String, query: String, contentDigest: String, idempotencyKey: String?,
        parameters: String
    ) -> String {
        var lines = [
            "\"@method\": \(method)",
            "\"@authority\": \(authority)",
            "\"@path\": \(path.isEmpty ? "/" : path)",
            "\"@query\": ?\(query)",
            "\"content-digest\": \(contentDigest)",
        ]
        if let idempotencyKey { lines.append("\"idempotency-key\": \(idempotencyKey)") }
        lines.append("\"@signature-params\": \(parameters)")
        return lines.joined(separator: "\n")
    }

    // MARK: Certificates

    /// The 32 bytes of `SEQUENCE { [1] EXPLICIT OCTET STRING }`, parsed by
    /// swift-asn1, or `nil` for anything else.
    static func nonceInExtension(_ value: ArraySlice<UInt8>) -> [UInt8]? {
        do {
            let node = try DER.parse(value)
            let octets = try DER.sequence(node, identifier: .sequence) { nodes in
                let inner = try DER.explicitlyTagged(&nodes, tagNumber: 1, tagClass: .contextSpecific) { node in
                    try ASN1OctetString(derEncoded: node)
                }
                guard nodes.next() == nil else { throw ASN1Error.invalidASN1Object(reason: "more than one element") }
                return inner
            }
            return octets.bytes.count == 32 ? Array(octets.bytes) : nil
        } catch {
            return nil
        }
    }

    /// A `Date` for swift-certificates, from the server's moment.
    static func date(of moment: Moment) -> Date {
        let (seconds, attoseconds) = moment.sinceEpoch.components
        return Date(timeIntervalSince1970: Double(seconds) + Double(attoseconds) / 1e18)
    }
}

/// The credential certificate's own extensions, declared handled so the
/// chain does not fail on them should Apple ever mark one critical: the
/// nonce (`1.2.840.113635.100.8.2`), which `verifyAttestation` checks itself.
/// It adds no requirement of its own.
struct CredentialCertificatePolicy: VerifierPolicy {
    let verifyingCriticalExtensions: [ASN1ObjectIdentifier] = [AppAttest.nonceExtension]

    func chainMeetsPolicyRequirements(chain: UnverifiedCertificateChain) -> PolicyEvaluationResult {
        .meetsPolicy
    }
}

/// What a server received, from any framework: the method, the path and
/// query exactly as received (percent-encoded, the query without its `?`),
/// the headers, and the body.
public struct SignedRequest: Sendable, Hashable {
    public let method: String
    public let path: String
    public let query: String
    public let body: [UInt8]
    private let headers: [Header]

    struct Header: Sendable, Hashable {
        let name: String
        let value: String
    }

    public init(method: String, path: String, query: String, headers: [(name: String, value: String)], body: [UInt8]) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers.map { Header(name: $0.name.lowercased(), value: $0.value) }
        self.body = body
    }

    /// Every value of header `name` (any case), trimmed, in order.
    func values(_ name: String) -> [String] {
        let lower = name.lowercased()
        return headers.filter { $0.name == lower }.map { $0.value.trimmingCharacters(in: .whitespaces) }
    }

    func has(_ name: String) -> Bool { !values(name).isEmpty }

    /// The values of `name` combined as RFC 9110 combines a list: with ", ".
    func combined(_ name: String) -> String? {
        let all = values(name)
        return all.isEmpty ? nil : all.joined(separator: ", ")
    }
}

/// Why a client says it cannot attest (`App-Attest: unsupported;reason=…`):
/// the same names as StoicApple's.
public enum AppAttestUnsupported: String, Sendable, Hashable, Codable {
    case mac, simulator
    case appExtension = "app-extension"
    case device
}

/// What a request's signature names, before anything is verified.
public struct RequestSignature: Sendable, Hashable {
    /// The key id (32 bytes); empty for a declaration.
    public let keyID: [UInt8]
    /// The challenge; empty for a declaration.
    public let nonce: [UInt8]
    /// The client's declaration that it cannot attest, if that is what it sent.
    public let unsupported: AppAttestUnsupported?
}

/// A request whose signature verified: what the genuine app signed.
public struct AttestedRequest: Sendable, Hashable {
    public let method: String
    /// The server's configured authority.
    public let authority: String
    public let path: String
    public let query: String
    public let idempotencyKey: String?
    public let body: [UInt8]
}

/// An assertion accepted: what it proved, and the key's record with its
/// counter advanced, to commit over the old revision.
public struct AcceptedAssertion: Sendable {
    public let verified: Verified<[UInt8], AppAttested>
    public let record: AppAttestKeyRecord
}

/// A request accepted, as ``AcceptedAssertion``.
public struct AcceptedRequest: Sendable {
    public let verified: Verified<AttestedRequest, AppAttested>
    public let record: AppAttestKeyRecord
}
#endif
