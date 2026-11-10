#if STOIC_ATTESTATION
import Foundation
import Stoic
@testable import StoicAttestation
import StoicTesting
import Testing

/// Real device captures (Vectors/apple-development.json): seven iPhones'
/// attestations and assertions, verified against Apple's real root at the
/// moment each was made. This is what checks Stoic's reading of Apple's
/// format against Apple's bytes: the CBOR, the nonce extension's encoding
/// and criticality, the credential id, the development AAGUID, the 37-byte
/// assertion data and the ECDSA message convention.
struct AppleSample: Decodable, Sendable, CustomTestStringConvertible {
    let source: String
    let iOSVersion: String
    let environment: String
    let teamID: String
    let bundleID: String
    let keyID: String
    let attestation: String
    let attestationClientData: String
    let attestedAt: String
    let assertion: String
    let assertionClientData: String
    let assertionCounter: UInt32

    var testDescription: String { "iOS \(iOSVersion), key \(keyID.prefix(6))…" }

    var app: AppID { get throws { try AppID("\(teamID).\(bundleID)") } }
    var attestationBytes: [UInt8] { Array(Data(base64Encoded: attestation) ?? Data()) }
    var assertionBytes: [UInt8] { Array(Data(base64Encoded: assertion) ?? Data()) }
    var challenge: [UInt8] { Array(Data(base64Encoded: attestationClientData) ?? Data()) }
    var clientData: [UInt8] { Array(Data(base64Encoded: assertionClientData) ?? Data()) }
    var moment: Moment { Moment(rfc3339: attestedAt) ?? .epoch }

    struct File: Decodable {
        struct Root: Decodable { let sha256: String }
        let root: Root
        let samples: [AppleSample]
    }

    static let file: File = {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Vectors/apple-development.json")
        // A missing or broken vector file fails every test that reads it, by name.
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else {
            return File(root: .init(sha256: ""), samples: [])
        }
        return file
    }()

    static var all: [AppleSample] { file.samples }
}

@Suite("App Attest: Apple's own bytes")
struct AppleVectorTests {
    @Test func theVectorsAreThere() {
        #expect(AppleSample.all.count == 7)
        #expect(Set(AppleSample.all.map(\.environment)) == ["development"])
    }

    @Test func applesRootIsTheOnePinned() {
        let hex = AppAttestRoot.apple.fingerprint.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
        #expect(hex == "1cb9823ba28ba6ad2d33a006941de2ae4f513ef1d4e831b9f7e0fa7b6242c932")
        #expect(hex == AppleSample.file.root.sha256)
        #expect(AppAttestRoot.apple.der.count == 549)
    }

    @Test(arguments: AppleSample.all)
    func anAttestationFromADeviceVerifiesAgainstApplesRoot(_ sample: AppleSample) async throws {
        let verified = try await AppAttest.verifyAttestation(
            sample.attestationBytes, keyID: sample.keyID, challenge: sample.challenge, app: try sample.app,
            environment: .development, root: .apple, at: sample.moment)
        #expect(Data(verified.value.id).base64EncodedString() == sample.keyID)
        #expect(verified.value.publicKey.count == 65 && verified.value.publicKey.first == 0x04)
        #expect(verified.value.environment == .development)
        #expect(verified.value.receipt.count > 1000, "Apple's receipt, kept")
        #expect(verified.evidence.root == AppAttestRoot.apple.fingerprint)
        #expect(verified.evidence.verifiedAt == sample.moment)
    }

    @Test(arguments: AppleSample.all)
    func anAssertionFromADeviceVerifiesWithItsAttestedKey(_ sample: AppleSample) async throws {
        let key = try await AppAttest.verifyAttestation(
            sample.attestationBytes, keyID: sample.keyID, challenge: sample.challenge, app: try sample.app,
            environment: .development, root: .apple, at: sample.moment)
        let record = AppAttestKeyRecord(enrolling: key, account: nil, attestation: sample.attestationBytes, at: sample.moment)
        let accepted = try AppAttest.verifyAssertion(sample.assertionBytes, over: sample.clientData, record: record)
        #expect(accepted.verified.value == sample.clientData)
        #expect(accepted.verified.evidence.counter == sample.assertionCounter)
        #expect(accepted.record.counter.highest == sample.assertionCounter)
        #expect(accepted.record.revision == 2)
        // The same assertion again is a replay.
        #expect(throws: AssertionFailure.replayed(counter: sample.assertionCounter)) {
            try AppAttest.verifyAssertion(sample.assertionBytes, over: sample.clientData, record: accepted.record)
        }
        // Over other data, the signature does not verify.
        #expect(throws: AssertionFailure.signatureInvalid) {
            try AppAttest.verifyAssertion(sample.assertionBytes, over: sample.clientData + [0], record: record)
        }
    }

    @Test(.failureMode("design/29", "the server's clock is wrong for the certificates"))
    func applesCredentialCertificateIsGoodForThreeDays() async throws {
        let sample = try #require(AppleSample.all.last)
        for moment in [sample.moment + .seconds(4 * 86_400), sample.moment - .seconds(2 * 86_400)] {
            await #expect(throws: AttestationFailure.self) {
                try await AppAttest.verifyAttestation(
                    sample.attestationBytes, keyID: sample.keyID, challenge: sample.challenge, app: try sample.app,
                    environment: .development, root: .apple, at: moment)
            }
        }
        let app = try sample.app
        do throws(AttestationFailure) {
            _ = try await AppAttest.verifyAttestation(
                sample.attestationBytes, keyID: sample.keyID, challenge: sample.challenge, app: app,
                environment: .development, root: .apple, at: sample.moment + .seconds(4 * 86_400))
        } catch {
            guard case .chain = error else { Issue.record("expected a chain failure, got \(error)"); return }
        }
    }

    @Test func applesBytesRefusedForTheWrongAppEnvironmentOrChallenge() async throws {
        let sample = try #require(AppleSample.all.first)
        func verify(app: AppID? = nil, environment: AppAttestEnvironment = .development, challenge: [UInt8]? = nil,
                    root: AppAttestRoot = .apple) async -> AttestationFailure? {
            do {
                _ = try await AppAttest.verifyAttestation(
                    sample.attestationBytes, keyID: sample.keyID, challenge: challenge ?? sample.challenge,
                    app: try app ?? sample.app, environment: environment, root: root, at: sample.moment)
                return nil
            } catch let error as AttestationFailure {
                return error
            } catch {
                return .malformed("\(error)")
            }
        }
        #expect(await verify(app: try AppID("ABCDEFGHIJ.app.other")) == .appIDMismatch)
        #expect(await verify(environment: .production) == .environmentMismatch(found: .development))
        #expect(await verify(challenge: Array("another challenge".utf8)) == .nonceMismatch)
        let stranger = try AppAttestStandIn(app: try sample.app, at: sample.moment)
        guard case .chain? = await verify(root: stranger.root) else { Issue.record("a chain to another root verified"); return }
    }
}
#endif
