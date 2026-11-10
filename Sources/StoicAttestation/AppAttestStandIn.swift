#if STOIC_ATTESTATION
internal import Crypto
internal import Foundation
public import Stoic
internal import SwiftASN1
internal import Synchronization
internal import X509

/// A software App Attest device and certificate authority, for tests:
/// real P-256 keys, a real chain to a test root, and the bytes a device
/// produces (design/29, Testing).
///
///     let device = try AppAttestStandIn(app: try AppID("A1B2C3D4E5.app.kindora"), at: .now)
///     let gate = AppAttestGate(…, root: device.root, …)
///     let key = device.generateKey()
///     let attestation = try device.attest(key, clientDataHash: hash)
///
/// It creates a P-384 root and intermediate with swift-certificates, and for
/// each key a P-256 pair, a credential certificate carrying the nonce
/// extension, and authenticator data with the app id's hash, the
/// environment's AAGUID and the credential id. Each assertion increments the
/// key's counter and is signed over the nonce as a device signs it. An
/// ``Attesting`` changes what one attestation says, so a test can present
/// every way an attestation is wrong.
///
/// It lives in `StoicAttestation`, behind its trait, as `ScriptedTransport`
/// lives in `StoicHTTP`. It is not a verifier of anything and never runs in
/// production: a gate given its root accepts only what it made.
public final class AppAttestStandIn: Sendable {
    /// The root a verifier must be given to accept what this device makes.
    public let root: AppAttestRoot
    public let app: AppID
    public let environment: AppAttestEnvironment

    private let intermediate: Certificate
    private let intermediateKey: P384.Signing.PrivateKey
    private let intermediateName: DistinguishedName
    private let issuedAt: Moment
    private let keys = Mutex<[String: Key]>([:])

    private struct Key: Sendable {
        let privateKey: P256.Signing.PrivateKey
        var counter: UInt32
        var attested: Bool
    }

    /// What one attestation says, for a test of each way it can be wrong.
    public struct Attesting: Sendable {
        /// Another app id's hash in the authenticator data.
        public var app: AppID?
        /// Another environment's AAGUID.
        public var environment: AppAttestEnvironment?
        /// The certificate carries the nonce of other data.
        public var wrongNonce = false
        /// A counter other than 0.
        public var counter: UInt32 = 0
        /// The credential certificate's validity, instead of three days
        /// from the stand-in's moment.
        public var validity: ClosedRange<Moment>?
        /// A third certificate in `x5c`.
        public var extraCertificate = false
        /// A credential id other than the key id.
        public var otherCredentialID = false

        public init() {}
    }

    /// A device and its authority, whose certificates are valid from a day
    /// before `moment` to ten years after; credential certificates for three
    /// days from it, as Apple's are.
    public init(app: AppID, environment: AppAttestEnvironment = .production, at moment: Moment = .now) throws {
        self.app = app
        self.environment = environment
        self.issuedAt = moment
        let rootKey = P384.Signing.PrivateKey()
        let rootName = try DistinguishedName {
            CommonName("Stoic Test App Attestation Root CA")
            OrganizationName("Stoic tests")
        }
        let notBefore = AppAttest.date(of: moment - .seconds(86_400))
        let notAfter = AppAttest.date(of: moment + .seconds(86_400 * 3650))
        let rootCertificate = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: .init(rootKey.publicKey),
            notValidBefore: notBefore, notValidAfter: notAfter, issuer: rootName, subject: rootName,
            signatureAlgorithm: .ecdsaWithSHA384,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
            },
            issuerPrivateKey: .init(rootKey))
        intermediateKey = P384.Signing.PrivateKey()
        intermediateName = try DistinguishedName {
            CommonName("Stoic Test App Attestation CA 1")
            OrganizationName("Stoic tests")
        }
        intermediate = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: .init(intermediateKey.publicKey),
            notValidBefore: notBefore, notValidAfter: notAfter, issuer: rootName, subject: intermediateName,
            signatureAlgorithm: .ecdsaWithSHA384,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
            },
            issuerPrivateKey: .init(rootKey))
        root = try AppAttestRoot(der: Self.der(rootCertificate))
    }

    /// A new key: its id, base64 of the SHA-256 of its X9.63 public key.
    public func generateKey() -> String {
        let key = P256.Signing.PrivateKey()
        let id = Base64.encode(Array(SHA256.hash(data: Array(key.publicKey.x963Representation))))
        keys.withLock { $0[id] = Key(privateKey: key, counter: 0, attested: false) }
        return id
    }

    /// An attestation object for `keyID` over a 32-byte client data hash.
    /// Like a device, it attests a key once.
    public func attest(_ keyID: String, clientDataHash: [UInt8], _ attesting: Attesting = Attesting()) throws -> [UInt8] {
        let key = try keys.withLock { keys throws -> P256.Signing.PrivateKey in
            guard var key = keys[keyID], !key.attested else { throw StandInError.invalidKey }
            key.attested = true
            keys[keyID] = key
            return key.privateKey
        }
        guard let id = Base64.canonical(keyID) else { throw StandInError.invalidKey }
        let point = Array(key.publicKey.x963Representation)
        let rpIDHash = (attesting.app ?? app).rpIDHash
        let aaguid = (attesting.environment ?? environment).aaguid
        let credentialID = attesting.otherCredentialID ? Array(SHA256.hash(data: id)) : id
        var authData = rpIDHash + [0x40] + Self.bigEndian(attesting.counter) + aaguid + [0x00, 0x20] + credentialID
        // The COSE key, as a device writes it; the verifier takes the key from the certificate.
        authData += CBORWriter.map([
            (.unsigned(1), .unsigned(2)), (.unsigned(3), .negative(7)), (.negative(1), .unsigned(1)),
            (.negative(2), .bytes(Array(point[1..<33]))), (.negative(3), .bytes(Array(point[33..<65]))),
        ])
        let nonce = Array(SHA256.hash(data: authData + (attesting.wrongNonce ? Array(repeating: 0, count: 32) : clientDataHash)))
        let window = attesting.validity ?? (issuedAt - .seconds(60))...(issuedAt + .seconds(3 * 86_400))
        let subject = try DistinguishedName {
            CommonName(id.map { String($0, radix: 16) }.joined())
            OrganizationalUnitName("AAA Certification")
            OrganizationName("Stoic tests")
        }
        let credential = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: .init(key.publicKey),
            notValidBefore: AppAttest.date(of: window.lowerBound), notValidAfter: AppAttest.date(of: window.upperBound),
            issuer: intermediateName, subject: subject, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                Certificate.Extension(oid: AppAttest.nonceExtension, critical: false, value: try Self.nonceExtension(nonce)[...])
            },
            issuerPrivateKey: .init(intermediateKey))
        var chain = [CBORWriter.Value.bytes(try Self.der(credential)), .bytes(try Self.der(intermediate))]
        if attesting.extraCertificate { chain.append(.bytes(try Self.der(intermediate))) }
        return CBORWriter.map([
            (.text("fmt"), .text("apple-appattest")),
            (.text("attStmt"), .map([(.text("x5c"), .array(chain)), (.text("receipt"), .bytes(Array("stand-in receipt".utf8)))])),
            (.text("authData"), .bytes(authData)),
        ])
    }

    /// An assertion object by `keyID` over a 32-byte client data hash, with
    /// the key's next counter, or `counter` (to reuse or skip one), and the
    /// stand-in's app id's hash, or `app`'s.
    public func assert(_ keyID: String, clientDataHash: [UInt8], counter: UInt32? = nil, app: AppID? = nil) throws -> [UInt8] {
        let (key, next) = try keys.withLock { keys throws -> (P256.Signing.PrivateKey, UInt32) in
            guard var key = keys[keyID], key.attested else { throw StandInError.invalidKey }
            let next = counter ?? (key.counter &+ 1)
            key.counter = max(key.counter, next)
            keys[keyID] = key
            return (key.privateKey, next)
        }
        let authenticatorData = (app ?? self.app).rpIDHash + [0x40] + Self.bigEndian(next)
        let nonce = Array(SHA256.hash(data: authenticatorData + clientDataHash))
        let signature = try key.signature(for: nonce)
        return CBORWriter.map([
            (.text("signature"), .bytes(Array(signature.derRepresentation))),
            (.text("authenticatorData"), .bytes(authenticatorData)),
        ])
    }

    /// The key is gone, as after a reinstall: every use of it fails.
    public func forget(_ keyID: String) {
        _ = keys.withLock { $0.removeValue(forKey: keyID) }
    }

    /// Why the stand-in refused, as a device's `invalidKey` would.
    public enum StandInError: Error, Sendable, Hashable {
        case invalidKey
    }

    private static func der(_ certificate: Certificate) throws -> [UInt8] {
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        return serializer.serializedBytes
    }

    /// `SEQUENCE { [1] EXPLICIT OCTET STRING nonce }`.
    static func nonceExtension(_ nonce: [UInt8]) throws -> [UInt8] {
        var serializer = DER.Serializer()
        try serializer.appendConstructedNode(identifier: .sequence) { sequence in
            try sequence.serialize(explicitlyTaggedWithTagNumber: 1, tagClass: .contextSpecific) { tagged in
                try tagged.serialize(ASN1OctetString(contentBytes: nonce[...]))
            }
        }
        return serializer.serializedBytes
    }

    static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }
}

/// Writes CBOR in shortest form, for the stand-in and the tests' defects.
enum CBORWriter {
    indirect enum Value: Sendable {
        case unsigned(UInt64)
        case negative(UInt64)
        case bytes([UInt8])
        case text(String)
        case array([Value])
        case map([(Value, Value)])
    }

    static func map(_ entries: [(Value, Value)]) -> [UInt8] { encode(.map(entries)) }

    static func encode(_ value: Value) -> [UInt8] {
        switch value {
        case .unsigned(let number): head(0, number)
        case .negative(let number): head(1, number - 1)
        case .bytes(let bytes): head(2, UInt64(bytes.count)) + bytes
        case .text(let text): head(3, UInt64(text.utf8.count)) + Array(text.utf8)
        case .array(let values): head(4, UInt64(values.count)) + values.flatMap(encode)
        case .map(let entries): head(5, UInt64(entries.count)) + entries.flatMap { encode($0.0) + encode($0.1) }
        }
    }

    /// The initial byte and argument, shortest form.
    static func head(_ major: UInt8, _ argument: UInt64) -> [UInt8] {
        let type = major << 5
        switch argument {
        case 0..<24: return [type | UInt8(argument)]
        case 24..<0x100: return [type | 24, UInt8(argument)]
        case 0x100..<0x1_0000: return [type | 25] + (0..<2).reversed().map { UInt8(truncatingIfNeeded: argument >> UInt64($0 * 8)) }
        case 0x1_0000..<0x1_0000_0000: return [type | 26] + (0..<4).reversed().map { UInt8(truncatingIfNeeded: argument >> UInt64($0 * 8)) }
        default: return [type | 27] + (0..<8).reversed().map { UInt8(truncatingIfNeeded: argument >> UInt64($0 * 8)) }
        }
    }
}
#endif
