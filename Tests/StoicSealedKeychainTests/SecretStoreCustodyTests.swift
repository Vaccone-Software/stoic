#if STOIC_CRYPTO
import Foundation
import StoicApple
import StoicSealed
@testable import StoicSealedKeychain
import StoicTesting
import Testing

@Suite("SecretStoreCustody")
struct SecretStoreCustodyTests {
    static let name = "app.keyring"

    /// Every way a secret store can refuse, and what the custody must say.
    /// One row per `SecretStoreError` case: the table in the type's documentation.
    static let mapping: [(SecretStoreError, CustodyError)] = [
        (.locked, .unavailable(.locked)),
        (.authenticationFailed, .unavailable(.accessDenied)),
        (.missingEntitlement, .unavailable(.accessDenied)),
        (.unavailable, .unavailable(.serviceUnavailable)),
        (.invalidKey, .invalidName),
        (.invalidValue, .invalidName),
        (.corrupted, .other(code: -1)),
        (.other(status: -25300), .other(code: -25300)),
        (.other(status: 0), .other(code: 0)),
        (.other(status: Int32.min), .other(code: Int(Int32.min))),
    ]

    /// A `switch` with no `default`: this stops compiling when `SecretStoreError`
    /// gains a case, which is the moment to give the table above a row for it.
    private static func everyCaseNeedsARow(_ error: SecretStoreError) {
        switch error {
        case .invalidKey, .invalidValue, .locked, .authenticationFailed, .missingEntitlement, .unavailable, .corrupted, .other: break
        }
    }

    // MARK: What it holds

    @Test(.failureMode("design/24", "a secret store holds nothing under the keyring's name"))
    func nothingIsNilNotAnError() throws {
        let custody = SecretStoreCustody(InMemorySecretStore())
        #expect(try custody.load(name: Self.name) == nil)
        // An absent name is not a failure to delete either.
        try custody.delete(name: Self.name)
        #expect(try custody.load(name: Self.name) == nil)
    }

    @Test func bytesRoundTripAndAStoreReplaces() throws {
        let secrets = InMemorySecretStore()
        let custody = SecretStoreCustody(secrets)
        let first: [UInt8] = Array(0...255)
        try custody.store(first, name: Self.name)
        #expect(try custody.load(name: Self.name) == first)
        #expect(secrets.keys == [Self.name])
        #expect(try secrets.get(Self.name) == Data(first), "the secret store holds exactly the bytes, under exactly the name")

        let second: [UInt8] = [9, 8, 7]
        try custody.store(second, name: Self.name)
        #expect(try custody.load(name: Self.name) == second, "store replaces")
        #expect(secrets.keys == [Self.name])
        try custody.delete(name: Self.name)
        #expect(try custody.load(name: Self.name) == nil && secrets.keys.isEmpty)
    }

    @Test func anEmptyNameIsInvalidAndNothingIsStored() throws {
        let secrets = InMemorySecretStore()
        let custody = SecretStoreCustody(secrets)
        #expect(throws: CustodyError.invalidName) { try custody.load(name: "") }
        #expect(throws: CustodyError.invalidName) { try custody.store([1], name: "") }
        #expect(throws: CustodyError.invalidName) { try custody.delete(name: "") }
        #expect(secrets.keys.isEmpty)
    }

    // MARK: What it says when the store refuses

    @Test(.failureMode("design/24", "a secret store is locked, refuses or cannot be reached"), arguments: SecretStoreCustodyTests.mapping)
    func everyRefusalOfTheStoreIsTheCustodyErrorTheTableSays(error: SecretStoreError, expected: CustodyError) throws {
        let secrets = InMemorySecretStore()
        try secrets.set(Data([1, 2, 3]), for: Self.name)
        let custody = SecretStoreCustody(secrets)

        secrets.failNext(with: error)
        #expect(throws: expected) { try custody.load(name: Self.name) }
        secrets.failNext(with: error)
        #expect(throws: expected) { try custody.store([4], name: Self.name) }
        secrets.failNext(with: error)
        #expect(throws: expected) { try custody.delete(name: Self.name) }

        // A refused call changed nothing, and the item is still there once the store answers.
        #expect(try custody.load(name: Self.name) == [1, 2, 3])
    }

    @Test(.failureMode("design/24", "a secret store is locked, refuses or cannot be reached"))
    func onlyAnInvalidArgumentIsASureThingTheItemMayExistForEveryOtherRefusal() {
        for (error, mapped) in Self.mapping {
            let invalidArgument = error == .invalidKey || error == .invalidValue
            #expect(mapped.itemMayExist == !invalidArgument, "\(error) → \(mapped)")
            if case .unavailable = mapped { #expect(mapped.itemMayExist) }
        }
    }

    @Test(.failureMode("design/24", "a secret store fails in a way it has no name for"))
    func aStatusTheStoreHasNoNameForKeepsItsCodeAndIsNotAbsent() throws {
        let secrets = InMemorySecretStore()
        let custody = SecretStoreCustody(secrets)
        secrets.failNext(with: .other(status: -25308))
        let error = #expect(throws: CustodyError.self) { try custody.load(name: Self.name) }
        #expect(error == .other(code: -25308))
        #expect(error?.itemMayExist == true, "its state is unknown, which is not absent")
        #expect(!"\(error as Any)".contains(Self.name), "no name in an error")
    }

    // MARK: Under a keyring

    @Test(.failureMode("design/24", "a secret store holds nothing under the keyring's name"))
    func aKeyringIsCreatedFailedOrReopenedOnTheStoreAnswer() throws {
        let secrets = InMemorySecretStore()
        let custody = SecretStoreCustody(secrets)
        #expect(throws: KeyringError.missing) { try Keyring.open(name: Self.name, custody: custody, ifMissing: .fail) }
        #expect(secrets.keys.isEmpty, "fail writes nothing")

        let created = try Keyring.open(name: Self.name, custody: custody, ifMissing: .create)
        #expect(created.created && secrets.keys == [Self.name])
        let rotated = try created.keyring.rotate()

        // A new process: the same store, a new custody value, the same keys.
        let again = try Keyring.open(name: Self.name, custody: SecretStoreCustody(secrets), ifMissing: .fail)
        #expect(!again.created)
        #expect(again.keyring.keyIDs == created.keyring.keyIDs && again.keyring.keyIDs.first == rotated.id)
        let sealed = try Sealing.seal(Array("kept".utf8), context: SealContext("app.test", "1"), key: try created.keyring.current)
        #expect(try Sealing.open(sealed, context: SealContext("app.test", "1"), keyring: again.keyring) == Array("kept".utf8))
    }

    @Test(.failureMode("design/24", "a secret store is locked, refuses or cannot be reached"), arguments: SecretStoreCustodyTests.mapping.map(\.0).filter { $0 != .invalidKey && $0 != .invalidValue })
    func aStoreThatRefusesNeverMakesAKeyringEvenWhenAskedTo(error: SecretStoreError) throws {
        // The keyring may well exist: creating one would orphan what it sealed.
        let secrets = InMemorySecretStore()
        let custody = SecretStoreCustody(secrets)
        for ifMissing in [Keyring.IfMissing.create, .fail] {
            secrets.failNext(with: error)
            do throws(KeyringError) {
                _ = try Keyring.open(name: Self.name, custody: custody, ifMissing: ifMissing)
                Issue.record("\(error): opening must not succeed")
            } catch {
                if case .custody(let refusal) = error {
                    #expect(refusal.itemMayExist, "\(refusal)")
                } else {
                    Issue.record("\(error)")
                }
            }
            #expect(secrets.keys.isEmpty, "\(error), \(ifMissing): nothing was created")
        }
    }

    @Test func aKeyringThatCannotBePersistedIsNotUsedAndTheStoreIsAsItWas() throws {
        let secrets = InMemorySecretStore()
        let custody = SecretStoreCustody(secrets)
        let ring = try Keyring.open(name: Self.name, custody: custody, ifMissing: .create).keyring
        let before = try secrets.get(Self.name)
        let keys = ring.keyIDs
        // The store is locked when the rotation writes (after the open's own store and read).
        secrets.failNext(with: .locked)
        #expect(throws: KeyringError.custody(.unavailable(.locked))) { try ring.rotate() }
        let after = try secrets.get(Self.name)
        #expect(ring.keyIDs == keys && after == before)
    }
}
#endif
