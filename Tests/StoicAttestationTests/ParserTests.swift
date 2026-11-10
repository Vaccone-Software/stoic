#if STOIC_ATTESTATION
import Foundation
import Stoic
@testable import StoicAttestation
import StoicTesting
import Testing

/// Back to bytes, in shortest form: what the reader accepted, written again.
func reencode(_ value: CBORValue) -> [UInt8] {
    func convert(_ value: CBORValue) -> CBORWriter.Value {
        switch value {
        case .unsigned(let number): .unsigned(number)
        case .bytes(let bytes): .bytes(bytes)
        case .text(let text): .text(text)
        case .array(let values): .array(values.map(convert))
        case .map(let map): .map(map.entries.map { (.text($0.key), convert($0.value)) })
        }
    }
    return CBORWriter.encode(convert(value))
}

@Suite("App Attest: the CBOR reader")
struct CBORReaderTests {
    func reads(_ bytes: [UInt8]) -> Result<CBORValue, CBORFailure> {
        Result { () throws(CBORFailure) in try CBORReader.read(bytes) }
    }

    func refusal(_ bytes: [UInt8]) -> String? {
        if case .failure(let failure) = reads(bytes) { failure.reason } else { nil }
    }

    @Test func theSubsetReads() throws {
        let object = CBORWriter.map([
            (.text("a"), .unsigned(23)), (.text("b"), .unsigned(24)), (.text("c"), .unsigned(70_000)),
            (.text("d"), .bytes([1, 2, 3])), (.text("e"), .text("é")), (.text("f"), .array([.unsigned(1), .array([])])),
        ])
        let value = try reads(object).get()
        #expect(value.map?.keys == ["a", "b", "c", "d", "e", "f"])
        #expect(value.map?["c"] == .unsigned(70_000) && value.map?["e"] == .text("é"))
        #expect(reencode(value) == object)
    }

    @Test(.failureMode("design/29", "an attestation or assertion is malformed or hostile CBOR"))
    func everyFormOutsideTheSubsetIsRefusedByName() {
        let cases: [([UInt8], String)] = [
            ([], "the input ends inside a value"),
            ([0x20], "a negative integer"),
            ([0xC0, 0x00], "a tag"),
            ([0xF4], "a float or simple value"),
            ([0xF9, 0x3C, 0x00], "a float or simple value"),
            ([0x5F, 0xFF], "an indefinite length"),
            ([0x1C], "reserved additional information"),
            ([0x18, 0x05], "an argument not in its shortest form"),
            ([0x19, 0x00, 0x10], "an argument not in its shortest form"),
            ([0x42, 0x01], "a length past the end of the input"),
            ([0x00, 0x00], "trailing bytes after the value"),
            ([0xA1, 0x01, 0x01], "a map key that is not text"),
            ([0xA2, 0x61, 0x61, 0x01, 0x61, 0x61, 0x02], "a duplicate map key"),
            ([0x62, 0xC3, 0x28], "text that is not UTF-8"),
            ([0x81, 0x81, 0x81, 0x81, 0x81, 0x00], "nesting deeper than 4"),
            ([0x91] + Array(repeating: 0x00, count: 17), "an array of more than 16 items"),
            ([0x1B, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF], "an argument not in its shortest form"),
            ([0x5B, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], "a length past the end of the input"),
            (Array(repeating: 0x00, count: 65 * 1024), "input over 65536 bytes"),
        ]
        for (bytes, reason) in cases {
            #expect(refusal(bytes) == reason, "\(bytes.prefix(12))")
        }
    }

    @Test func randomBytesNeverTrapAndNeverReadTwoWays() {
        var random = SplitMix(state: 29)
        var accepted = 0
        for _ in 0..<200_000 {
            let bytes = (0..<Int.random(in: 0...24, using: &random)).map { _ in UInt8.random(in: 0...255, using: &random) }
            if case .success(let value) = reads(bytes) {
                accepted += 1
                #expect(reencode(value) == bytes, "one reading: what is accepted is the one way to write it")
            }
        }
        #expect(accepted > 1000, "the generator reaches the subset")
    }

    @Test func mutationsOfARealAttestationNeverTrap() throws {
        let sample = try #require(AppleSample.all.first)
        let valid = sample.attestationBytes
        var random = SplitMix(state: 7)
        for _ in 0..<20_000 {
            var bytes = valid
            switch Int.random(in: 0...3, using: &random) {
            case 0: bytes[Int.random(in: 0..<bytes.count, using: &random)] ^= UInt8(1) << UInt8.random(in: 0...7, using: &random)
            case 1: bytes.removeLast(Int.random(in: 1...bytes.count, using: &random))
            case 2: bytes.insert(UInt8.random(in: 0...255, using: &random), at: Int.random(in: 0...bytes.count, using: &random))
            default: bytes[Int.random(in: 0..<min(bytes.count, 64), using: &random)] = UInt8.random(in: 0...255, using: &random)
            }
            if case .success(let value) = reads(bytes) { #expect(reencode(value) == bytes) }
        }
    }

    /// Every byte of an attestation is authenticated (by the chain, or by
    /// the nonce over authData) or checked, except the receipt's contents:
    /// verifying Apple's receipt belongs to the risk metric, which is Not
    /// built. A receipt edited in transit is kept as it arrived.
    @Test func mutatedAttestationsAndAssertionsAreRefusedNeverAccepted() async throws {
        let sample = try #require(AppleSample.all.last)
        let app = try sample.app
        let valid = sample.attestationBytes
        let receipt = try #require(try CBORReader.read(valid).map?["attStmt"]?.map?["receipt"]?.bytes)
        let receiptRange = try #require(valid.firstRange(of: receipt))
        var random = SplitMix(state: 11)
        var tried = 0
        while tried < 300 {
            let index = Int.random(in: 0..<valid.count, using: &random)
            guard !receiptRange.contains(index) else { continue }
            tried += 1
            var bytes = valid
            bytes[index] ^= UInt8(1) << UInt8.random(in: 0...7, using: &random)
            await #expect(throws: AttestationFailure.self, "byte \(index)") {
                _ = try await AppAttest.verifyAttestation(
                    bytes, keyID: sample.keyID, challenge: sample.challenge, app: app, environment: .development, at: sample.moment)
            }
        }
        var edited = valid
        edited[receiptRange.lowerBound + 100] ^= 0x01
        let kept = try await AppAttest.verifyAttestation(
            edited, keyID: sample.keyID, challenge: sample.challenge, app: app, environment: .development, at: sample.moment)
        #expect(kept.value.receipt != receipt, "the receipt is not authenticated here")
        let key = try await AppAttest.verifyAttestation(
            sample.attestationBytes, keyID: sample.keyID, challenge: sample.challenge, app: app, environment: .development, at: sample.moment)
        let record = AppAttestKeyRecord(enrolling: key, account: nil, attestation: sample.attestationBytes, at: sample.moment)
        for index in sample.assertionBytes.indices {
            for bit in UInt8(0)...7 {
                var bytes = sample.assertionBytes
                bytes[index] ^= 1 << bit
                #expect(throws: AssertionFailure.self) { try AppAttest.verifyAssertion(bytes, over: sample.clientData, record: record) }
            }
        }
    }
}

@Suite("App Attest: the structured-field reader")
struct StructuredFieldTests {
    @Test func theHeadersReadAsDesignTwentyNineWritesThem() throws {
        let input = try SFParser.dictionary(#"attest=("@method" "@path");keyid="AAEC";nonce="AQI=";alg="apple-app-attest", other=("@method");created=1618884473"#)
        guard case .innerList(let items, let parameters)? = input["attest"] else { Issue.record("no attest"); return }
        #expect(items.map(\.item) == [.string("@method"), .string("@path")])
        #expect(parameters.entries.map(\.key) == ["keyid", "nonce", "alg"])
        #expect(input["other"] != nil, "another signature's integer parameter reads too")
        #expect(try SFParser.dictionary("attest=:AQI=:")["attest"] == .item(.bytes([1, 2]), SFParameters()))
        let declaration = try SFParser.item("unsupported;reason=app-extension")
        #expect(declaration.0 == .token("unsupported") && declaration.1["reason"] == .token("app-extension"))
    }

    @Test func everyFormOutsideTheSubsetIsRefused() {
        let dictionaries = [
            "attest=:AQI=:, attest=:AQI=:",           // a duplicate key: RFC 8941 keeps the last; two readings
            "attest=:AQI:",                            // base64 without its padding
            "attest=:A Q=:",                           // a space inside
            "attest=1.5",                              // a decimal
            "Attest=1",                                // a key not lower case
            "attest=1,",                               // a trailing comma
            "attest=(\"a\"",                           // an inner list not closed
            "attest=\"a\\n\"",                         // an escape other than \" and \\
            "attest=\"é\"",                            // outside visible ASCII
            "attest=1;a;a",                            // a duplicate parameter
            "attest=1234567890123456",                 // 16 digits
            "attest=?2",
            "attest=1 x",
            String(repeating: "a", count: 16 * 1024 + 1),
        ]
        for text in dictionaries {
            #expect(throws: SFFailure.self, "\(text.prefix(40))") { try SFParser.dictionary(text) }
        }
    }

    @Test func randomTextNeverTraps() {
        var random = SplitMix(state: 3)
        let alphabet = Array(#"attest=():;"\?*-.,= 0123456789abcAQI+/"#.utf8)
        for _ in 0..<100_000 {
            let bytes = (0..<Int.random(in: 0...40, using: &random)).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &random)] }
            let text = String(decoding: bytes, as: UTF8.self)
            _ = try? SFParser.dictionary(text)
            _ = try? SFParser.item(text)
        }
    }
}

@Suite("App Attest: the counter window")
struct AssertionCounterTests {
    @Test func aCounterAboveIsTakenWithinIsTakenOnceBelowIsRefused() {
        var counter = AssertionCounter.enrolled
        func take(_ value: UInt32, window: Int = 32) -> AssertionFailure? {
            switch counter.accepting(value, reorderWindow: window) {
            case .success(let next): counter = next; return nil
            case .failure(let failure): return failure
            }
        }
        #expect(take(0) == .replayed(counter: 0), "the attestation's own counter")
        #expect(take(5) == nil && take(3) == nil && take(4) == nil)
        #expect(take(3) == .replayed(counter: 3))
        #expect(take(100) == nil)
        #expect(take(68) == nil, "32 below: inside the window")
        #expect(take(67) == .counterRegressed(counter: 67, highest: 100))
        #expect(take(101, window: 0) == nil, "a window of 0 is Apple's literal rule: greater than the highest")
        #expect(take(100, window: 0) == .counterRegressed(counter: 100, highest: 101))
        #expect(take(101, window: 0) == .replayed(counter: 101))
        #expect(take(UInt32.max) == nil)
        #expect(take(1) == .counterExhausted)
    }

    /// The window against a model, a set of accepted counters: each counter
    /// accepted at most once, every counter above the highest accepted, none
    /// further below than the window, and every unseen one within it.
    @Test func theWindowMatchesTheModelOverAMillionSequences() {
        var random = SplitMix(state: 2026)
        for _ in 0..<1_000_000 {
            let window = Int.random(in: 0...63, using: &random)
            var counter = AssertionCounter.enrolled
            var accepted: Set<UInt32> = [0]
            var highest: UInt32 = 0
            for _ in 0..<6 {
                let value = UInt32.random(in: 0...80, using: &random)
                let expected = value > highest || (highest - value <= UInt32(window) && !accepted.contains(value))
                switch counter.accepting(value, reorderWindow: window) {
                case .success(let next):
                    if !expected { Issue.record("accepted \(value) with highest \(highest), window \(window)"); return }
                    counter = next
                    accepted.insert(value)
                    highest = max(highest, value)
                case .failure:
                    if expected { Issue.record("refused \(value) with highest \(highest), window \(window)"); return }
                }
                if counter.highest != highest { Issue.record("highest \(counter.highest), model \(highest)"); return }
            }
        }
    }
}

@Suite("App Attest: challenges")
struct AppAttestChallengeTests {
    let challenges = try! AppAttestChallenges(keys: [challengeKey]) // stoic:allow(force-try): a 32-byte key

    @Test func aChallengeRoundTripsAndEveryOneBitChangeIsRefused() throws {
        let now = TestClock.wallClockStart
        let challenge = challenges.issue(.requests, at: now)
        #expect(challenge.bytes.count == 42 && challenge.bytes[0] == 1 && challenge.bytes[1] == 2 && challenge.lifetime == .seconds(300))
        let checked = try challenges.check(challenge.bytes, for: .requests, at: now)
        #expect(checked.issued == now && checked.expires == now + .seconds(300) && checked.id == Array(challenge.bytes[10..<26]))
        for index in challenge.bytes.indices {
            for bit in UInt8(0)...7 {
                var bytes = challenge.bytes
                bytes[index] ^= 1 << bit
                let expected: ChallengeRefusal = index == 0 ? .malformed : .forged
                #expect(throws: expected) { try challenges.check(bytes, for: .requests, at: now) }
            }
        }
    }

    @Test func purposeAgeFutureAndKeysAreChecked() throws {
        let now = TestClock.wallClockStart
        let enrolment = challenges.issue(.enrolment, at: now)
        #expect(enrolment.lifetime == .seconds(600))
        #expect(throws: ChallengeRefusal.wrongPurpose) { try challenges.check(enrolment.bytes, for: .requests, at: now) }
        #expect(throws: ChallengeRefusal.expired) { try challenges.check(enrolment.bytes, for: .enrolment, at: now + .seconds(601)) }
        #expect(throws: ChallengeRefusal.fromTheFuture) { try challenges.check(enrolment.bytes, for: .enrolment, at: now - .seconds(31)) }
        _ = try challenges.check(enrolment.bytes, for: .enrolment, at: now - .seconds(29))
        #expect(throws: ChallengeRefusal.malformed) { try challenges.check(Array(enrolment.bytes.prefix(41)), for: .enrolment, at: now) }
        // Rotation: the new key first, the old one still checks.
        let rotated = try AppAttestChallenges(keys: [Secret(Array(repeating: 9, count: 32)), challengeKey])
        _ = try rotated.check(enrolment.bytes, for: .enrolment, at: now)
        #expect(throws: ChallengeRefusal.badKey) { try AppAttestChallenges(keys: [Secret([1, 2, 3])]) }
        #expect(throws: ChallengeRefusal.badKey) { try AppAttestChallenges(keys: []) }
        #expect(AppAttestChallenges.constantTimeEqual([1, 2, 3], [1, 2, 3]) && !AppAttestChallenges.constantTimeEqual([1, 2, 3], [1, 2, 4]))
    }
}
#endif
