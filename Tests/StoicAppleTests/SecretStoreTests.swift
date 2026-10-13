import Foundation
import Security
import Stoic
import StoicTesting
import Testing

@testable import StoicApple

@Suite("Secret store")
struct SecretStoreTests {
    static let token = Data("hunter2-token".utf8)

    @Test(.failureMode("design/21", "there is no value under the key"))
    func anAbsentKeyIsNil() throws {
        #expect(try InMemorySecretStore().get("token") == nil)
    }

    @Test func aValueComesBack() throws {
        let store = InMemorySecretStore()
        try store.set(Self.token, for: "token")
        #expect(try store.get("token") == Self.token)
    }

    @Test(.failureMode("design/21", "a key is set twice"))
    func theSecondValueReplacesTheFirst() throws {
        let store = InMemorySecretStore()
        try store.set(Data("one".utf8), for: "token")
        try store.set(Data("two".utf8), for: "token")
        #expect(try store.get("token") == Data("two".utf8))
        #expect(store.keys == ["token"])
    }

    @Test(.failureMode("design/21", "a key is deleted that is not there"))
    func deletingWhatIsNotThereSucceeds() throws {
        let store = InMemorySecretStore()
        try store.delete("token")
        try store.set(Self.token, for: "token")
        try store.delete("token")
        #expect(try store.get("token") == nil)
    }

    @Test(.failureMode("design/21", "the key is empty"))
    func anEmptyKeyIsRefused() {
        let store = InMemorySecretStore()
        #expect(throws: SecretStoreError.invalidKey) { try store.get("") }
        #expect(throws: SecretStoreError.invalidKey) { try store.set(Self.token, for: "") }
        #expect(throws: SecretStoreError.invalidKey) { try store.delete("") }
    }

    @Test(.failureMode("design/21", "the value is empty"))
    func anEmptyValueIsRefusedAndTheOldOneStays() throws {
        let store = InMemorySecretStore()
        try store.set(Self.token, for: "token")
        #expect(throws: SecretStoreError.invalidValue) { try store.set(Data(), for: "token") }
        #expect(try store.get("token") == Self.token)
    }

    @Test(.failureMode("design/21", "the device is locked"))
    func aLockedStoreFailsOnceWithoutChangingAnything() throws {
        let store = InMemorySecretStore(["token": Self.token])
        store.failNext(with: .locked)
        #expect(throws: SecretStoreError.locked) { try store.set(Data("new".utf8), for: "token") }
        #expect(try store.get("token") == Self.token)
        #expect(SecretStoreError.locked.retryDecision == .retry)
        #expect(SecretStoreError.missingEntitlement.retryDecision == .stop)
    }

    @Test(.failureMode("design/21", "an error is printed or logged"))
    func errorsNameNeitherTheKeyNorTheValue() {
        let store = InMemorySecretStore()
        let errors: [SecretStoreError] = [
            .invalidKey, .invalidValue, .locked, .authenticationFailed, .missingEntitlement,
            .unavailable, .corrupted, .other(status: -25300),
        ]
        for error in errors {
            store.failNext(with: error)
            do throws(SecretStoreError) {
                try store.set(Self.token, for: "account-name")
            } catch {
                for text in ["\(error)", String(reflecting: error), error.description] {
                    #expect(!text.contains("account-name"))
                    #expect(!text.contains("hunter2"))
                }
            }
        }
    }

    @Test(.failureMode("design/21", "the app is not entitled to the Keychain"))
    func aMissingEntitlementIsRecognised() {
        #expect(SecretStoreError(status: errSecMissingEntitlement) == .missingEntitlement)
        #expect(SecretStoreError(status: errSecInteractionNotAllowed) == .locked)
        #expect(SecretStoreError(status: errSecAuthFailed) == .authenticationFailed)
        #expect(SecretStoreError(status: errSecNotAvailable) == .unavailable)
    }

    @Test(.failureMode("design/21", "the Keychain returns a status Stoic does not know"))
    func anUnknownStatusKeepsOnlyItsNumber() {
        let error = SecretStoreError(status: errSecDecode)
        #expect(error == .other(status: errSecDecode))
        #expect(error.description == "status \(errSecDecode)")
    }

    @Test func theKeychainStoreDefaultsToAfterFirstUnlockThisDeviceOnly() {
        let store = KeychainSecretStore(service: "com.example.app")
        #expect(store.accessibility == .afterFirstUnlockThisDeviceOnly)
        #expect(store.accessGroup == nil)
        #expect(Set(KeychainSecretStore.Accessibility.allCases.map { $0.attribute as String }).count == 5)
    }
}
