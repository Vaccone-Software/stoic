#if canImport(DeviceCheck) && canImport(CryptoKit)
import Foundation
import Stoic
@testable import StoicApple
import Testing

/// App Attest key records released builds kept in the keychain, read by this
/// one (design/32, design/29): the fixtures in Compatibility/, each recorded
/// by the release in its folder's name, with that release's own code.
@Suite("App Attest: the key records released builds kept")
struct AppAttestRecordCompatibilityTests {
    static let directory = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Compatibility/app-attest.record")

    /// The records the fixtures hold, by name: every phase.
    static let named: [String: AppAttestRecord] = {
        let challenge = AppAttestChallenge(bytes: Array(0..<32), lifetime: .seconds(600))
        let at = Moment(sinceEpoch: .seconds(1_767_225_600))
        return [
            "generated": .generated("key-id-1"),
            "attesting": .attesting("key-id-1", challenge, at: at),
            "attested": .attested("key-id-1", challenge, attestation: Array(repeating: 0xA5, count: 48)),
            "enrolled": .enrolled("key-id-1"),
            "refused": .refused(code: "key_refused", until: at + .seconds(86_400)),
        ]
    }()

    /// Every release's records, as the attester reads them: each the record
    /// it was made from, complete, and written again as the same JSON object
    /// (the encoder's key order is not part of the format), so that release
    /// reads what this one writes.
    @Test func aKeyRecordReadsAsTheReleaseWroteIt() throws {
        var read = 0
        for release in try FileManager.default.contentsOfDirectory(atPath: Self.directory.path).sorted() {
            let folder = Self.directory.appending(path: release)
            for file in try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() where file.hasSuffix(".json") {
                let name = String(file.dropLast(".json".count))
                let bytes = try Data(contentsOf: folder.appending(path: file))
                let record = try JSONDecoder().decode(AppAttestRecord.self, from: bytes)
                #expect(record == Self.named[name], "\(release)/\(name)")
                #expect(record.isComplete, "\(release)/\(name)")
                let again = try JSONSerialization.jsonObject(with: try record.encoded()) as? NSDictionary
                let recorded = try JSONSerialization.jsonObject(with: bytes) as? NSDictionary
                #expect(again != nil && again == recorded, "\(release)/\(name) is written differently today")
                read += 1
            }
        }
        #expect(read >= Self.named.count)
    }
}
#endif
