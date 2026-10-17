#if STOIC_CRYPTO
import Crypto
import Dispatch
import Foundation
import Stoic
@testable import StoicSealed
import StoicTesting
import Testing

@Suite("Keyring and custody")
struct KeyringTests {
    static let name = "test.keyring"
    static let context = SealContext("app.notes", "n")

    func open(_ custody: InMemoryKeyCustody, _ ifMissing: Keyring.IfMissing = .fail) throws -> Keyring.Opening {
        try Keyring.open(name: Self.name, custody: custody, ifMissing: ifMissing)
    }

    // MARK: Opening

    @Test(.failureMode("design/24", "the custody holds no keyring and the caller asked to create one"))
    func openingWithCreateMakesOneKeyAndSaysSo() throws {
        let custody = InMemoryKeyCustody()
        let opened = try open(custody, .create)
        #expect(opened.created)
        #expect(opened.keyring.keyIDs.count == 1)
        #expect(custody.names == [Self.name])
        #expect(custody.contents(of: Self.name)?.count == 7 + 48 + 16, "one key in the format the contract gives")
        #expect(try opened.keyring.current.id == opened.keyring.keyIDs[0])
    }

    @Test(.failureMode("design/24", "the custody holds no keyring and the caller asked to fail"))
    func openingWithFailThrowsMissingAndCreatesNothing() throws {
        let custody = InMemoryKeyCustody()
        #expect(throws: KeyringError.missing) { try open(custody, .fail) }
        #expect(custody.names.isEmpty)
        #expect(custody.calls.map(\.operation) == [.load], "it asked, and wrote nothing")
    }

    @Test func aKeyringOpensAgainWithItsKeysAndIsNotCreatedTwice() throws {
        let custody = InMemoryKeyCustody()
        let first = try open(custody, .create).keyring
        let rotated = try first.rotate()
        let again = try open(custody, .create)
        #expect(!again.created)
        #expect(again.keyring.keyIDs == first.keyIDs)
        #expect(try again.keyring.current.id == rotated.id)
        let sealed = try Sealing.seal(bytes("x"), context: Self.context, key: rotated)
        #expect(try Sealing.open(sealed, context: Self.context, keyring: again.keyring) == bytes("x"))
    }

    // The case that must never go wrong: a custody that cannot be reached is
    // not an empty one. Creating a keyring then would orphan everything sealed
    // under the one that is really there.
    @Test(.failureMode("design/24", "the custody is unavailable when a keyring is opened"),
          arguments: [CustodyError.Reason.locked, .accessDenied, .userCancelled, .interactionNotAllowed, .serviceUnavailable])
    func anUnavailableCustodyNeverCreatesAKey(reason: CustodyError.Reason) throws {
        let custody = InMemoryKeyCustody()
        for ifMissing in [Keyring.IfMissing.create, .fail] {
            custody.failNext(with: .unavailable(reason))
            let error = #expect(throws: KeyringError.self) { try open(custody, ifMissing) }
            #expect(error == .custody(.unavailable(reason)))
            #expect(custody.names.isEmpty, "no keyring was made")
            #expect(!custody.calls.contains { $0.operation == .store }, "nothing was written")
        }
        // Where a ring does exist, an unavailable custody leaves it alone too.
        let existing = try open(custody, .create).keyring
        let before = custody.contents(of: Self.name)
        custody.failNext(with: .unavailable(reason))
        #expect(throws: KeyringError.custody(.unavailable(reason))) { try open(custody, .create) }
        #expect(custody.contents(of: Self.name) == before)
        #expect(existing.keyIDs.count == 1)
    }

    @Test func anyOtherCustodyFailureIsAFailureNotAnAbsence() throws {
        let custody = InMemoryKeyCustody()
        custody.failNext(with: .other(code: -25300))
        #expect(throws: KeyringError.custody(.other(code: -25300))) { try open(custody, .create) }
        #expect(custody.names.isEmpty)
        #expect(CustodyError.other(code: 1).itemMayExist && CustodyError.unavailable(.locked).itemMayExist)
    }

    // MARK: A custody item that is not a ring is left alone

    static func goodRing() -> [UInt8] { RingFormat.encode([SealingKey.generate(), SealingKey.generate()]) }

    @Test(.failureMode("design/24", "the custody item is not a keyring this release reads"))
    func anItemThatIsNotARingIsCorruptAndNeverReplaced() throws {
        var damaged: [[UInt8]] = [[], bytes("SKR"), bytes("not a keyring at all"), Array(Self.goodRing().dropLast()), Self.goodRing() + [0]]
        let good = Self.goodRing()
        for index in [0, 3, 5, 7, 20, good.count - 17, good.count - 1] {       // magic, key bytes, count, checksum
            var flipped = good
            flipped[index] ^= 0x01
            damaged.append(flipped)
        }
        var noKeys = Array("SKR1".utf8) + [1, 0, 0]
        noKeys += Array(SHA256Prefix.of(noKeys))
        damaged.append(noKeys)
        let one = SealingKey.generate()
        damaged.append(RingFormat.encode([one, one]))                          // a key listed twice
        for item in damaged {
            let custody = InMemoryKeyCustody()
            custody.put(item, name: Self.name)
            for ifMissing in [Keyring.IfMissing.create, .fail] {
                let error = #expect(throws: KeyringError.self, "\(item.count) bytes opened") { try open(custody, ifMissing) }
                if let error, case .unsupportedVersion = error {} else { #expect(error == .corrupt, "\(item.count) bytes") }
                #expect(custody.contents(of: Self.name) == item, "the item is exactly as it was")
                #expect(!custody.calls.contains { $0.operation == .store || $0.operation == .delete })
            }
        }
    }

    @Test func aNewerFormatIsSaidSoAndLeftUntouched() throws {
        let custody = InMemoryKeyCustody()
        var future = Self.goodRing()
        future[4] = 2
        custody.put(future, name: Self.name)
        #expect(throws: KeyringError.unsupportedVersion(2)) { try open(custody, .create) }
        #expect(custody.contents(of: Self.name) == future)
    }

    @Test func theRingFormatIsWhatTheContractSays() throws {
        let one = SealingKey.generate(), two = SealingKey.generate()
        let encoded = RingFormat.encode([one, two])
        #expect(Array(encoded[0..<4]) == Array("SKR1".utf8))
        #expect(encoded[4] == 1)
        #expect(encoded[5] == 2 && encoded[6] == 0, "the count, little-endian")
        #expect(Array(encoded[7..<55]) == one.exportedForWrapping(), "the current key first: identifier then key")
        #expect(Array(encoded[55..<103]) == two.exportedForWrapping())
        #expect(encoded.count == 7 + 2 * 48 + 16)
        #expect(Array(encoded[103...]) == Array(SHA256Prefix.of(Array(encoded[..<103]))))
        let decoded = try RingFormat.decode(encoded)
        #expect(decoded.map(\.id) == [one.id, two.id])
    }

    // MARK: Rotation

    @Test(.failureMode("design/24", "a keyring is rotated"))
    func rotationPersistsTheRingBeforeItReturnsTheKey() throws {
        let custody = InMemoryKeyCustody()
        let ring = try open(custody, .create).keyring
        let old = try ring.current
        let fresh = try ring.rotate()
        #expect(fresh.id != old.id)
        #expect(try ring.current.id == fresh.id)
        #expect(ring.keyIDs == [fresh.id, old.id], "the current key first, the old one kept")
        // The custody already holds the new key at the moment rotate returned.
        let persisted = try RingFormat.decode(try #require(custody.contents(of: Self.name)))
        #expect(persisted.map(\.id) == [fresh.id, old.id])
        // The store came before the readback, and both before any use.
        #expect(custody.calls.suffix(2).map(\.operation) == [.store, .load])
        // What the old key sealed still opens.
        let oldValue = try Sealing.seal(bytes("old"), context: Self.context, key: old)
        #expect(try Sealing.open(oldValue, context: Self.context, keyring: ring) == bytes("old"))
    }

    @Test(.failureMode("design/24", "the custody fails or loses the write of a rotation"))
    func aRotationThatCannotBeStoredChangesNothing() throws {
        let custody = InMemoryKeyCustody()
        let ring = try open(custody, .create).keyring
        let before = ring.keyIDs
        let stored = custody.contents(of: Self.name)

        custody.failNext(with: .unavailable(.locked), on: .store)
        #expect(throws: KeyringError.custody(.unavailable(.locked))) { try ring.rotate() }
        #expect(ring.keyIDs == before)
        #expect(custody.contents(of: Self.name) == stored)

        // A custody that says yes and keeps nothing: the new key is not used.
        custody.inject(.dropWrite, on: .store)
        #expect(throws: KeyringError.notPersisted) { try ring.rotate() }
        #expect(ring.keyIDs == before, "a key the custody does not hold is never published")
        #expect(custody.contents(of: Self.name) == stored)

        // And it recovers: the next rotation works.
        _ = try ring.rotate()
        #expect(ring.keyIDs.count == 2)
    }

    @Test func aRotationWhoseReadBackIsRefusedIsNotUsedAndTheNextOneIsFine() throws {
        // The write landed but the check could not be made. The key is not
        // returned for use; the custody holds a ring with a key that sealed
        // nothing, which the next open reads and the next rotation replaces.
        let custody = InMemoryKeyCustody()
        let ring = try open(custody, .create).keyring
        let before = ring.keyIDs
        custody.failNext(with: .unavailable(.interactionNotAllowed), on: .load)
        #expect(throws: KeyringError.custody(.unavailable(.interactionNotAllowed))) { try ring.rotate() }
        #expect(ring.keyIDs == before)
        let persisted = try RingFormat.decode(try #require(custody.contents(of: Self.name)))
        #expect(persisted.count == 2, "the new ring is what the custody holds")
        // A reopen reads it, with both keys, so nothing is lost either way.
        let reopened = try open(custody).keyring
        #expect(Set(reopened.keyIDs) == Set(persisted.map(\.id)))
        #expect(Set(reopened.keyIDs).isSuperset(of: before))
    }

    // MARK: Retirement and destruction

    @Test(.failureMode("design/24", "a key is retired"))
    func retiringAKeyMakesWhatItSealedUnreadable() throws {
        let custody = InMemoryKeyCustody()
        let ring = try open(custody, .create).keyring
        let old = try ring.current
        let secret = try Sealing.seal(bytes("secret"), context: Self.context, key: old)
        let fresh = try ring.rotate()
        #expect(try ring.retire(id: old.id))
        #expect(ring.keyIDs == [fresh.id])
        #expect(ring.key(id: old.id) == nil)
        #expect(throws: SealError.unknownKey(old.id)) { try Sealing.open(secret, context: Self.context, keyring: ring) }
        // Persisted: a new process finds no old key either.
        let reopened = try open(custody).keyring
        #expect(reopened.keyIDs == [fresh.id])
        #expect(throws: SealError.unknownKey(old.id)) { try Sealing.open(secret, context: Self.context, keyring: reopened) }
        // Retiring again, or retiring a stranger, is not an error.
        #expect(try ring.retire(id: old.id) == false)
        #expect(try ring.retire(id: SealingKey.generate().id) == false)
    }

    @Test func theCurrentKeyCannotBeRetired() throws {
        let custody = InMemoryKeyCustody()
        let ring = try open(custody, .create).keyring
        let stored = custody.contents(of: Self.name)
        #expect(throws: KeyringError.cannotRetireCurrent) { try ring.retire(id: ring.current.id) }
        #expect(throws: KeyringError.cannotRetireCurrent) { try ring.retire(ids: ring.keyIDs) }
        #expect(custody.contents(of: Self.name) == stored)
    }

    @Test func severalKeysAreRetiredInOneStoredRing() throws {
        let custody = InMemoryKeyCustody()
        let ring = try open(custody, .create).keyring
        _ = try ring.rotate(); _ = try ring.rotate(); _ = try ring.rotate()
        let all = ring.keyIDs
        let storesBefore = custody.calls.filter { $0.operation == .store }.count
        #expect(try ring.retire(ids: Array(all.dropFirst())) == 3)
        #expect(custody.calls.filter { $0.operation == .store }.count == storesBefore + 1, "one write: no window with only some gone")
        #expect(ring.keyIDs == [all[0]])
    }

    @Test func aRetirementThatCannotBeStoredChangesNothing() throws {
        let custody = InMemoryKeyCustody()
        let ring = try open(custody, .create).keyring
        let old = try ring.current
        _ = try ring.rotate()
        custody.failNext(with: .unavailable(.accessDenied), on: .store)
        #expect(throws: KeyringError.custody(.unavailable(.accessDenied))) { try ring.retire(id: old.id) }
        #expect(ring.key(id: old.id) != nil, "the key is still there: it was not shredded")
    }

    @Test(.failureMode("design/24", "a keyring is destroyed"))
    func destroyingDeletesTheItemAndEndsSealing() throws {
        let custody = InMemoryKeyCustody()
        let ring = try open(custody, .create).keyring
        let key = try ring.current
        let sealed = try Sealing.seal(bytes("gone"), context: Self.context, key: key)
        try ring.destroy()
        #expect(custody.names.isEmpty)
        #expect(throws: KeyringError.destroyed) { try ring.current }
        #expect(throws: KeyringError.destroyed) { try ring.rotate() }
        #expect(throws: KeyringError.destroyed) { try ring.retire(id: key.id) }
        #expect(ring.key(id: key.id) == nil && ring.keyIDs.isEmpty)
        #expect(throws: SealError.unknownKey(key.id)) { try Sealing.open(sealed, context: Self.context, keyring: ring) }
        #expect(throws: KeyringError.missing) { try open(custody, .fail) }
        // A destroyed ring that cannot be deleted is not destroyed.
        let other = try open(custody, .create).keyring
        custody.failNext(with: .unavailable(.locked), on: .delete)
        #expect(throws: KeyringError.custody(.unavailable(.locked))) { try other.destroy() }
        #expect(try other.current.id == other.keyIDs[0], "still usable")
        #expect(custody.names == [Self.name])
    }

    // MARK: Two processes

    @Test(.failureMode("design/24", "a second process rotates the keyring the first has open"))
    func reloadingSeesAnotherProcessesRotation() throws {
        let custody = InMemoryKeyCustody()
        let writer = try open(custody, .create).keyring
        let reader = try open(custody, .fail).keyring
        let fresh = try writer.rotate()
        let sealed = try Sealing.seal(bytes("new"), context: Self.context, key: fresh)
        #expect(throws: SealError.unknownKey(fresh.id)) { try Sealing.open(sealed, context: Self.context, keyring: reader) }
        try reader.reload()
        #expect(try Sealing.open(sealed, context: Self.context, keyring: reader) == bytes("new"))
        #expect(try reader.current.id == fresh.id)
    }

    @Test func reloadingAKeyringTheCustodyNoLongerHoldsDestroysIt() throws {
        let custody = InMemoryKeyCustody()
        let ring = try open(custody, .create).keyring
        try custody.delete(name: Self.name)
        #expect(throws: KeyringError.missing) { try ring.reload() }
        #expect(throws: KeyringError.destroyed) { try ring.current }
    }

    @Test func aReloadThatCannotReadLeavesTheKeyringAsItWas() throws {
        let custody = InMemoryKeyCustody()
        let ring = try open(custody, .create).keyring
        let ids = ring.keyIDs
        custody.failNext(with: .unavailable(.locked), on: .load)
        #expect(throws: KeyringError.custody(.unavailable(.locked))) { try ring.reload() }
        custody.put(bytes("garbage"), name: Self.name)
        #expect(throws: KeyringError.corrupt) { try ring.reload() }
        #expect(ring.keyIDs == ids)
        #expect(try ring.current.id == ids[0])
    }

    // MARK: Threads

    @Test(.failureMode("design/24", "keys are used from many threads while the keyring rotates"))
    func manyThreadsSealAndOpenWhileTheKeyringRotates() throws {
        let custody = InMemoryKeyCustody()
        let ring = try open(custody, .create).keyring
        let problems = SendableBox<[String]>([])
        let rotations = 25
        DispatchQueue.concurrentPerform(iterations: 9) { worker in
            if worker == 0 {
                for _ in 0..<rotations {
                    do { try ring.rotate() } catch { problems.mutate { $0.append("rotate: \(error)") } }
                }
                return
            }
            for index in 0..<400 {
                do {
                    let key = try ring.current
                    let value = bytes("w\(worker)-\(index)")
                    let sealed = try Sealing.seal(value, context: Self.context, key: key)
                    // The key that sealed it is in the ring (rotation only adds), and in the custody.
                    guard try Sealing.open(sealed, context: Self.context, keyring: ring) == value else {
                        problems.mutate { $0.append("a value changed") }
                        return
                    }
                } catch {
                    problems.mutate { $0.append("worker \(worker): \(error)") }
                }
            }
        }
        #expect(problems.value.isEmpty, "\(problems.value.prefix(3))")
        #expect(ring.keyIDs.count == rotations + 1)
        let persisted = try RingFormat.decode(try #require(custody.contents(of: Self.name)))
        #expect(persisted.map(\.id) == ring.keyIDs, "memory and custody agree, current key first")
    }

    // MARK: Nothing secret shows

    @Test(.failureMode("design/24", "a key, error or event is printed, logged or reflected over"))
    func aKeyringAndItsErrorsNameNoKey() throws {
        let custody = InMemoryKeyCustody()
        let ring = try open(custody, .create).keyring
        let stored = try #require(custody.contents(of: Self.name))
        let keyBytes = Array(stored[(7 + 16)..<(7 + 48)])
        let hex = hexString(keyBytes)
        var dumped = ""
        dump(ring, to: &dumped)
        let keyringErrors: [KeyringError] = [
            .missing, .corrupt, .unsupportedVersion(2), .destroyed, .cannotRetireCurrent, .notPersisted, .tooManyKeys,
            .custody(.unavailable(.locked)), .custody(.other(code: -25300)), .custody(.invalidName),
        ]
        let sealErrors: [SealError] = [
            .tampered, .unknownKey(try ring.current.id), .torn, .notSealed, .unsupportedFormat(version: 2, algorithm: 1), .encryptionFailed,
        ]
        let storeErrors: [SealedStoreError] = [
            .seal(.tampered), .unreadable(count: 3), .compactedButNotShredded(.custody(.unavailable(.locked))),
            .keyring(.destroyed),
        ]
        let errors: [any Error] = keyringErrors + sealErrors + storeErrors + [CustodyError.unavailable(.userCancelled)]
        #expect(!dumped.contains("custody") && !dumped.contains("items"), "reflection does not reach the custody")
        for line in ["\(ring)", String(reflecting: ring), dumped] {
            #expect(!line.contains(String(hex.prefix(8))))
            #expect(!line.contains(ring.keyIDs[0].description), "a keyring shows no identifier either")
            #expect(line.contains(Self.name) && line.contains("1"), "it shows its name and how many keys")
        }
        for error in errors {
            for line in ["\(error)", String(reflecting: error), "\(String(describing: error))"] {
                #expect(!line.contains(String(hex.prefix(8))))
                #expect(!line.contains(Self.name), "an error never quotes the custody item's name: \(line)")
                #expect(!line.contains(ring.keyIDs[0].description), "no key identifier in a description: \(line)")
            }
        }
    }

    @Test func theKeyringReportsItsLifeAndNeverAKey() throws {
        let events = RecordingInstrumentation()
        let custody = InMemoryKeyCustody()
        let identifiers = try withAmbient({ $0.instrumentation = events }) { () throws -> [String] in
            let ring = try open(custody, .create).keyring
            _ = try open(custody, .create)                    // opened again: not created again
            var seen = ring.keyIDs.map(\.description)
            let old = try ring.current
            seen.append(try ring.rotate().id.description)
            try ring.retire(id: old.id)
            try ring.destroy()
            return seen
        }
        #expect(events.names.map(\.rawValue) == [
            "sealed.keyring_created", "sealed.key_rotated", "sealed.keys_retired", "sealed.keyring_destroyed",
        ])
        #expect(events.events(named: "sealed.key_rotated").first?["keys"].map(\.description) == "2")
        #expect(events.events(named: "sealed.keys_retired").first?["retired"].map(\.description) == "1")
        for event in events.events {
            #expect(event["name"].map(\.description) == Self.name)
            let text = event.fields.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            for identifier in identifiers { #expect(!text.contains(identifier), "a key identifier is in \(event.name.rawValue)") }
        }
    }

    @Test func custodyRefusesAnEmptyNameAndBehavesAsTheContractSays() throws {
        let custody = InMemoryKeyCustody()
        #expect(throws: CustodyError.invalidName) { try custody.load(name: "") }
        #expect(throws: CustodyError.invalidName) { try custody.store([1], name: "") }
        #expect(try custody.load(name: "a") == nil, "nil only when absent")
        try custody.delete(name: "a")
        try custody.store([1, 2], name: "a")
        try custody.store([3], name: "a")
        #expect(try custody.load(name: "a") == [3], "store replaces")
        #expect(CustodyError.unavailable(.locked).retryDecision == .retry)
        #expect(CustodyError.unavailable(.userCancelled).retryDecision == .stop)
        #expect(CustodyError.unavailable(.accessDenied).retryDecision == .stop)
        #expect(!CustodyError.invalidName.itemMayExist)
    }
}

/// The first 16 bytes of SHA-256, as the ring's checksum, computed here
/// independently of the library's own.
enum SHA256Prefix {
    static func of(_ bytes: [UInt8]) -> [UInt8] {
        Array(Crypto.SHA256.hash(data: bytes).prefix(16))
    }
}
#endif
