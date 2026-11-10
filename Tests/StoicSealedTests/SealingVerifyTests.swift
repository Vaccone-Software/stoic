#if STOIC_CRYPTO
import Foundation
import Stoic
@testable import StoicSealed
import StoicTesting
import Testing

/// `Sealing.verify`: opening as a verification (design/28).
@Suite("Sealing, verified")
struct SealingVerifyTests {
    static let context = SealContext("app.notes", "note-1")
    static let plaintext = bytes("the quick brown fox")

    let key = SealingKey.generate()

    func ringHolding(_ key: SealingKey) throws -> Keyring {
        let custody = InMemoryKeyCustody()
        custody.put(RingFormat.encode([key]), name: "test.keyring")
        return try Keyring.open(name: "test.keyring", custody: custody, ifMissing: .fail).keyring
    }

    func verifying(_ sealed: [UInt8], context: SealContext = Self.context, ring: Keyring) -> Result<Verified<[UInt8], AuthenticatedDecryption>, SealError> {
        Result { () throws(SealError) in try Sealing.verify(Claimed(sealed), context: context, keyring: ring) }
    }

    @Test(.failureMode("design/28", "a sealed value is verified"))
    func verifyingProvesThePlaintextOrThrowsWhatOpenThrows() throws {
        let ring = try ringHolding(key)
        let sealed = try Sealing.seal(Self.plaintext, context: Self.context, key: key)

        let verified = try verifying(sealed, ring: ring).get()
        #expect(verified.value == Self.plaintext)
        #expect(verified.evidence.key == key.id)
        #expect(verified.evidence.purpose == "app.notes")
        #expect(AuthenticatedDecryption.proves.contains("unchanged"))
        // Content evidence: a value decoded from the plaintext keeps it.
        let text = verified.deriving { String(decoding: $0, as: UTF8.self) }
        #expect(text.value == "the quick brown fox" && text.evidence == verified.evidence)

        // Every refusal, the same as `open`'s.
        var altered = sealed
        altered[altered.count - 1] ^= 0x01
        let otherRing = try ringHolding(SealingKey.generate())
        var version = sealed
        version[4] = 9
        let cases: [([UInt8], SealContext, Keyring)] = [
            (bytes("plain text"), Self.context, ring),
            (Array(sealed.prefix(20)), Self.context, ring),
            (version, Self.context, ring),
            (sealed, Self.context, otherRing),
            (altered, Self.context, ring),
            (sealed, SealContext("app.notes", "note-2"), ring),
        ]
        for (input, context, keyring) in cases {
            let opened = Result { () throws(SealError) in try Sealing.open(input, context: context, keyring: keyring) }
            guard case .failure(let expected) = opened else { Issue.record("open accepted a bad input"); continue }
            #expect(verifying(input, context: context, ring: keyring).map(\.value) == .failure(expected))
        }
        let kinds = cases.map { input, context, keyring -> String in
            if case .failure(let error) = verifying(input, context: context, ring: keyring) { return error.label }
            return "verified"
        }
        #expect(kinds == ["not_sealed", "torn", "unsupported_format", "unknown_key", "tampered", "tampered"])
    }

    @Test(.failureMode("design/28", "an older sealed copy replaces the newer one"))
    func anOlderCopyVerifiesBecauseDecryptionDoesNotProveFreshness() throws {
        let ring = try ringHolding(key)
        let older = try Sealing.seal(bytes("balance: 100"), context: Self.context, key: key)
        let newer = try Sealing.seal(bytes("balance: 10"), context: Self.context, key: key)
        #expect(try verifying(newer, ring: ring).get().value == bytes("balance: 10"))
        // Someone with write access puts the older file back.
        let replayed = try verifying(older, ring: ring).get()
        #expect(replayed.value == bytes("balance: 100"), "it verifies: AuthenticatedDecryption says nothing about freshness")
        #expect(!AuthenticatedDecryption.proves.contains("latest"))
    }
}
#endif
