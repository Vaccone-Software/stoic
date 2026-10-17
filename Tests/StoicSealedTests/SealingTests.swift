#if STOIC_CRYPTO
import Crypto
import Foundation
@testable import StoicSealed
import StoicTesting
import Testing

@Suite("Sealing")
struct SealingTests {
    static let context = SealContext("app.notes", "note-1")
    static let plaintext = bytes("the quick brown fox")

    let key = SealingKey.generate()

    /// A keyring holding exactly `key`, so a test seals under a key it holds.
    func ringHolding(_ key: SealingKey) throws -> Keyring {
        let custody = InMemoryKeyCustody()
        custody.put(RingFormat.encode([key]), name: "test.keyring")
        return try Keyring.open(name: "test.keyring", custody: custody, ifMissing: .fail).keyring
    }

    // MARK: Round trips

    @Test(.failureMode("design/24", "a value is sealed and opened with its context and a key the keyring holds"))
    func aSealedValueOpensWithItsContextAndKey() throws {
        let ring = try ringHolding(key)
        let sealed = try Sealing.seal(Self.plaintext, context: Self.context, key: key)
        #expect(try Sealing.open(sealed, context: Self.context, keyring: ring) == Self.plaintext)
        #expect(try Sealing.open(sealed, context: Self.context, key: key) == Self.plaintext)
        #expect(sealed.count == Self.plaintext.count + Sealing.overhead)
        #expect(Sealing.overhead == 50)
    }

    @Test(arguments: [0, 1, 15, 16, 17, 1000, 100_000])
    func everySizeRoundTripsAndNeverShowsItsPlaintext(count: Int) throws {
        let ring = try ringHolding(key)
        let plaintext = (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
        let sealed = try Sealing.seal(plaintext, context: Self.context, key: key)
        #expect(try Sealing.open(sealed, context: Self.context, keyring: ring) == plaintext)
        #expect(sealed.count == count + 50)
        if count >= 16 { #expect(!contains(sealed, Array(plaintext.prefix(16))), "the plaintext is not in the sealed bytes") }
    }

    @Test func theSameValueSealedTwiceIsDifferentBytes() throws {
        let one = try Sealing.seal(Self.plaintext, context: Self.context, key: key)
        let two = try Sealing.seal(Self.plaintext, context: Self.context, key: key)
        #expect(one != two, "a fresh nonce every time")
        #expect(Array(one[22..<34]) != Array(two[22..<34]))
    }

    // MARK: The format, checked against the cipher itself

    @Test func theLayoutIsWhatTheContractSaysAndTheCipherAgrees() throws {
        let sealed = try Sealing.seal(Self.plaintext, context: Self.context, key: key)
        let exported = key.exportedForWrapping()
        #expect(Array(sealed[0..<4]) == Array("SSL1".utf8))
        #expect(sealed[4] == 1)
        #expect(sealed[5] == 1)
        #expect(Array(sealed[6..<22]) == Array(exported[0..<16]), "the key identifier")
        let nonce = try AES.GCM.Nonce(data: sealed[22..<34])
        let ciphertext = sealed[34..<(sealed.count - 16)]
        let tag = sealed[(sealed.count - 16)...]
        #expect(ciphertext.count == Self.plaintext.count)

        // The associated data as the contract writes it: the 22 header bytes,
        // the domain byte (1 for a value), then each part as a 4-byte
        // little-endian length and its UTF-8.
        var associated = Array(sealed[0..<22]) + [1]
        for part in ["app.notes", "note-1"] {
            let utf8 = Array(part.utf8)
            associated += [UInt8(utf8.count), 0, 0, 0] + utf8
        }
        let symmetric = SymmetricKey(data: exported[16...])
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        #expect(Array(try AES.GCM.open(box, using: symmetric, authenticating: associated)) == Self.plaintext)

        // And the other way: a value assembled by hand from the contract opens.
        let handmade = try AES.GCM.seal(Self.plaintext, using: symmetric, authenticating: associated)
        let assembled = Array(sealed[0..<22]) + Array(handmade.nonce) + Array(handmade.ciphertext) + Array(handmade.tag)
        #expect(try Sealing.open(assembled, context: Self.context, key: key) == Self.plaintext)
    }

    @Test func nonceNeverRepeatsInManySeals() throws {
        var nonces: Set<[UInt8]> = []
        for index in 0..<50_000 {
            let sealed = try Sealing.seal([UInt8(truncatingIfNeeded: index)], context: Self.context, key: key)
            nonces.insert(Array(sealed[22..<34]))
        }
        #expect(nonces.count == 50_000)
    }

    // MARK: Header, ciphertext and tag: every bit

    /// The kind a flipped bit at `offset` must report, from the header's own
    /// layout: the magic is how a sealed value is recognised, the version and
    /// algorithm how it is read, the key identifier how its key is found (all
    /// read before anything is authenticated); the nonce, ciphertext and tag
    /// are the cipher's.
    static func expectation(at offset: Int, key: SealingKey) -> (SealError) -> Bool {
        switch offset {
        case 0..<4: { $0 == .notSealed }
        case 4..<6: { if case .unsupportedFormat = $0 { true } else { false } }
        case 6..<22: { if case .unknownKey = $0 { true } else { false } }
        default: { $0 == .tampered }
        }
    }

    @Test(.failureMode("design/24", "any byte of the header, nonce, ciphertext or tag is altered"))
    func everyBitFlipIsRefusedAsItsFieldDeserves() throws {
        let ring = try ringHolding(key)
        let sealed = try Sealing.seal(bytes("twenty bytes of data"), context: Self.context, key: key)
        for offset in sealed.indices {
            for bit in 0..<8 {
                var damaged = sealed
                damaged[offset] ^= 1 << UInt8(bit)
                let error = #expect(throws: SealError.self, "byte \(offset) bit \(bit) opened") {
                    try Sealing.open(damaged, context: Self.context, keyring: ring)
                }
                if let error { #expect(Self.expectation(at: offset, key: key)(error), "byte \(offset) bit \(bit) gave \(error)") }
            }
        }
    }

    @Test func aKeyIdentifierEditedToAnotherKeyTheRingHoldsIsTampered() throws {
        let other = SealingKey.generate()
        let custody = InMemoryKeyCustody()
        custody.put(RingFormat.encode([key, other]), name: "r")
        let ring = try Keyring.open(name: "r", custody: custody, ifMissing: .fail).keyring
        var sealed = try Sealing.seal(Self.plaintext, context: Self.context, key: key)
        sealed.replaceSubrange(6..<22, with: other.id.bytes)
        #expect(throws: SealError.tampered) { try Sealing.open(sealed, context: Self.context, keyring: ring) }
    }

    // MARK: Cut short, and added to

    @Test(.failureMode("design/24", "a sealed value is cut short"))
    func aCutValueIsTornTamperedOrNotSealedByWhereItWasCut() throws {
        let ring = try ringHolding(key)
        let sealed = try Sealing.seal(bytes("0123456789"), context: Self.context, key: key)
        for count in 0..<sealed.count {
            let cut = Array(sealed.prefix(count))
            let error = #expect(throws: SealError.self, "a value cut to \(count) bytes opened") {
                try Sealing.open(cut, context: Self.context, keyring: ring)
            }
            switch count {
            case 0..<4: #expect(error == .notSealed, "shorter than the magic cannot be told from plaintext (\(count) bytes)")
            case 4..<50: #expect(error == .torn, "\(count) bytes")
            default: #expect(error == .tampered, "a cut that leaves a whole header is only a failed tag (\(count) bytes)")
            }
        }
    }

    @Test func bytesAddedToTheEndAreTampered() throws {
        let ring = try ringHolding(key)
        let sealed = try Sealing.seal(Self.plaintext, context: Self.context, key: key)
        #expect(throws: SealError.tampered) { try Sealing.open(sealed + [0], context: Self.context, keyring: ring) }
    }

    // MARK: Context

    @Test(.failureMode("design/24", "a sealed value is opened under another context"))
    func aValueMovedToAnotherContextDoesNotOpen() throws {
        let ring = try ringHolding(key)
        let sealed = try Sealing.seal(Self.plaintext, context: Self.context, key: key)
        let others: [SealContext] = [
            SealContext("app.notes", "note-2"),          // another object
            SealContext("app.clips", "note-1"),          // another kind
            SealContext("app.notes"),                    // no id
            SealContext("app.notes", "note-1", "extra"), // one more
            SealContext("note-1", "app.notes"),          // swapped
            "app.notes",                                 // the purpose alone, as a literal
            SealContext("app.notes", "Note-1"),          // case
        ]
        for other in others {
            #expect(throws: SealError.tampered) { try Sealing.open(sealed, context: other, keyring: ring) }
        }
        // And the right one still works.
        #expect(try Sealing.open(sealed, context: SealContext("app.notes", "note-1"), keyring: ring) == Self.plaintext)
    }

    @Test func partsAreLengthPrefixedSoABoundaryCannotShift() throws {
        let ring = try ringHolding(key)
        let sealed = try Sealing.seal(Self.plaintext, context: SealContext("ab", "c"), key: key)
        #expect(throws: SealError.tampered) { try Sealing.open(sealed, context: SealContext("a", "bc"), keyring: ring) }
        #expect(throws: SealError.tampered) { try Sealing.open(sealed, context: SealContext("abc"), keyring: ring) }
        #expect(throws: SealError.tampered) { try Sealing.open(sealed, context: SealContext("ab", "c", ""), keyring: ring) }
        #expect(SealContext("a").appending("b") == SealContext("a", "b"))
    }

    @Test func aLayersDerivedContextsNeverEqualOneTheAppWrote() throws {
        let ring = try ringHolding(key)
        let base = SealContext("app.log", "main")
        // The app writes what a journal would derive for record 7.
        let appWrote = SealContext("app.log", "main", "7")
        let record = base.deriving(.journalRecord, number: 7)
        let snapshot = base.deriving(.journalSnapshot, number: 7)
        #expect(appWrote.associatedData != record.associatedData)
        #expect(record.associatedData != snapshot.associatedData)
        let sealed = try Sealing.seal(Self.plaintext, context: record, key: key)
        #expect(throws: SealError.tampered) { try Sealing.open(sealed, context: appWrote, keyring: ring) }
        #expect(throws: SealError.tampered) { try Sealing.open(sealed, context: snapshot, keyring: ring) }
        #expect(throws: SealError.tampered) { try Sealing.open(sealed, context: base.deriving(.journalRecord, number: 8), keyring: ring) }
    }

    // MARK: Keys

    @Test(.failureMode("design/24", "a sealed value names a key the keyring does not hold"))
    func aKeyTheRingDoesNotHoldIsUnknownNotTampered() throws {
        let (ring, _) = try makeRing()
        let sealed = try Sealing.seal(Self.plaintext, context: Self.context, key: key)
        let error = #expect(throws: SealError.self) { try Sealing.open(sealed, context: Self.context, keyring: ring) }
        #expect(error == .unknownKey(key.id))
        #expect(!"\(String(describing: error))".contains(key.id.description), "the description leaves even the identifier out")
        #expect(throws: SealError.unknownKey(key.id)) { try Sealing.open(sealed, context: Self.context, key: .generate()) }
    }

    @Test(.failureMode("design/24", "plaintext, or another format, is opened"))
    func plaintextIsNotSealedAndNothingIsTried() throws {
        let (ring, _) = try makeRing()
        for plain in [bytes(""), bytes("hello"), bytes("{\"a\":1}"), Array(repeating: 0, count: 100), bytes("SSL"), bytes("SSL0 plus more bytes here")] {
            #expect(throws: SealError.notSealed) { try Sealing.open(plain, context: Self.context, keyring: ring) }
            #expect(!Sealing.isSealed(plain))
        }
    }

    @Test func aFormatThisVersionDoesNotReadIsSaidSo() throws {
        let (ring, _) = try makeRing()
        var sealed = try Sealing.seal(Self.plaintext, context: Self.context, key: key)
        sealed[4] = 2
        #expect(throws: SealError.unsupportedFormat(version: 2, algorithm: 1)) { try Sealing.open(sealed, context: Self.context, keyring: ring) }
        sealed[4] = 1
        sealed[5] = 9
        #expect(throws: SealError.unsupportedFormat(version: 1, algorithm: 9)) { try Sealing.open(sealed, context: Self.context, keyring: ring) }
    }

    @Test func theKeyIdentifierCanBeReadWithoutDecrypting() throws {
        let sealed = try Sealing.seal(Self.plaintext, context: Self.context, key: key)
        #expect(Sealing.isSealed(sealed))
        #expect(try Sealing.keyID(of: sealed) == key.id)
        #expect(throws: SealError.notSealed) { try Sealing.keyID(of: bytes("plain")) }
        #expect(throws: SealError.torn) { try Sealing.keyID(of: Array(sealed.prefix(20))) }
        #expect(throws: SealError.torn) { try Sealing.keyID(of: Array(sealed.prefix(4))) }
    }

    // MARK: Keys never show

    @Test(.failureMode("design/24", "a key, error or event is printed, logged or reflected over"))
    func aKeyShowsItsIdentifierAndNothingElse() throws {
        let material = (0..<32).map { UInt8(0xC0 + $0) }
        let id = (0..<16).map { UInt8(0xA0 + $0) }
        let known = try #require(SealingKey(importing: id + material))
        var dumped = ""
        dump(known, to: &dumped)
        let shown = [
            "\(known)", known.description, known.debugDescription, String(reflecting: known), dumped,
            "\(Mirror(reflecting: known).children.map { "\($0.label ?? ""): \($0.value)" })",
            "\([known])", String(describing: Optional(known)),
        ]
        let hex = hexString(material)
        let base64 = Data(material).base64EncodedString()
        for text in shown {
            #expect(text.contains(known.id.description), "the identifier is shown")
            #expect(!text.contains(String(hex.prefix(8))), "no key byte in hex: \(text)")
            #expect(!text.uppercased().contains(String(hex.prefix(8)).uppercased()))
            #expect(!text.contains(String(base64.prefix(8))))
            #expect(!text.contains("192, 193"))
            #expect(!text.contains("192\n"))
        }
    }

    @Test func aKeyRoundTripsThroughExportAndImport() throws {
        let exported = key.exportedForWrapping()
        #expect(exported.count == 48 && exported.count == SealingKey.exportedByteCount)
        let imported = try #require(SealingKey(importing: exported))
        #expect(imported.id == key.id)
        let sealed = try Sealing.seal(Self.plaintext, context: Self.context, key: key)
        #expect(try Sealing.open(sealed, context: Self.context, key: imported) == Self.plaintext)
        #expect(SealingKey(importing: Array(exported.dropLast())) == nil)
        #expect(SealingKey(importing: exported + [0]) == nil)
        #expect(SealingKey(importing: []) == nil)
        #expect(KeyID(bytes: [1, 2, 3]) == nil)
    }

    @Test func generatedKeysAndIdentifiersDiffer() {
        let keys = (0..<200).map { _ in SealingKey.generate() }
        #expect(Set(keys.map(\.id)).count == 200)
        #expect(Set(keys.map { $0.exportedForWrapping() }).count == 200)
    }

    @Test func aPerObjectKeyKeptInsideASealedRecordOpensItsObject() throws {
        let (ring, _) = try makeRing()
        let object = SealingKey.generate()
        let blob = try Sealing.seal(bytes("the object"), context: SealContext("app.blob", "b1"), key: object)
        // The wrapped key travels inside a record sealed under the ring.
        let wrapped = try Sealing.seal(object.exportedForWrapping(), context: SealContext("app.blob.key", "b1"), key: ring.current)
        let unwrapped = try Sealing.open(wrapped, context: SealContext("app.blob.key", "b1"), keyring: ring)
        let recovered = try #require(SealingKey(importing: unwrapped))
        #expect(try Sealing.open(blob, context: SealContext("app.blob", "b1"), key: recovered) == bytes("the object"))
        // Drop the wrapped key and the blob is noise: the ring cannot open it.
        #expect(throws: SealError.unknownKey(object.id)) { try Sealing.open(blob, context: SealContext("app.blob", "b1"), keyring: ring) }
    }
}
#endif
