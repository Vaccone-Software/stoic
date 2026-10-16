@testable import Stoic
import Testing

/// The frozen derivation of a declared operation's key inside an enclosing
/// one (design/22, Keys), and the SHA-256 under it.
@Suite("Derived keys")
struct DerivedKeyTests {
    // MARK: SHA-256

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String($0, radix: 16).count == 1 ? "0" + String($0, radix: 16) : String($0, radix: 16) }.joined()
    }

    @Test(arguments: [
        ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
         "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
        ("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
         "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"),
    ])
    func sha256MatchesTheStandardVectors(_ message: String, _ digest: String) {
        #expect(Self.hex(SHA256.hash(message.utf8)) == digest)
    }

    @Test func sha256OfAMillionAs() {
        #expect(Self.hex(SHA256.hash(repeatElement(UInt8(ascii: "a"), count: 1_000_000)))
            == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    @Test func sha256IsTheSameFedInPieces() {
        // Lengths around the 55-, 56- and 64-byte padding boundaries.
        for length in [0, 1, 55, 56, 57, 63, 64, 65, 119, 120, 128, 1000] {
            let bytes = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
            var pieces = SHA256()
            var index = 0
            while index < bytes.count {
                let end = min(bytes.count, index + 1 + index % 13)
                pieces.update(bytes[index..<end])
                index = end
            }
            #expect(pieces.finalize() == SHA256.hash(bytes), "length \(length)")
        }
    }

    // MARK: The derivation

    @Test func theDerivedKeyIsFrozen() {
        // Version 1 of the derivation, computed independently (Python's
        // hashlib over the same name): a changed value here is a double
        // charge for every outbox entry in flight.
        let parent = IdempotencyKey(rawValue: "order-42")
        #expect(IdempotencyKey.derived(fromEnclosing: parent, backend: "payments", operation: "subscribe", occurrence: 0).rawValue
            == "f1538199-d383-8107-ad6a-096410d47137")
        #expect(IdempotencyKey.derived(fromEnclosing: parent, backend: "payments", operation: "subscribe", occurrence: 1).rawValue
            == "974228f6-b9b7-811d-94fb-c628aeeabad6")
        #expect(IdempotencyKey.derived(fromEnclosing: parent, backend: "payments", operation: "refund", occurrence: 0).rawValue
            == "1d8c6b8b-1441-8f47-8c8a-a2ac04965017")
    }

    @Test func aDerivedKeyIsAVersion8UUID() {
        let key = IdempotencyKey.derived(fromEnclosing: IdempotencyKey(rawValue: "x"), backend: "b", operation: "o", occurrence: 3).rawValue
        let characters = Array(key)
        #expect(characters.count == 36)
        #expect([8, 13, 18, 23].allSatisfy { characters[$0] == "-" })
        #expect(characters[14] == "8")
        #expect("89ab".contains(characters[19]))
        #expect(key == key.lowercased())
    }
}
