import Foundation
#if canImport(Security)
import Security
#endif
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

    // The Keychain is Apple's; these exercise its status codes and defaults.
    #if canImport(Security)
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

    /// Only `errSecItemNotFound` is "nothing there". The statuses a locked,
    /// refusing or missing keychain answers with all throw, so a caller that
    /// creates a replacement on `nil` can never be driven to it by one of them.
    @Test(.failureMode("design/21", "the item is not in the Keychain"))
    func onlyItemNotFoundIsAbsence() throws {
        #expect(try KeychainSecretStore.interpret(copyStatus: errSecItemNotFound, result: nil) == nil)
        #expect(try KeychainSecretStore.interpret(copyStatus: errSecSuccess, result: Data("v".utf8) as CFData) == Data("v".utf8))
        #expect(throws: SecretStoreError.corrupted) { try KeychainSecretStore.interpret(copyStatus: errSecSuccess, result: nil) }
        // Every status the system documents for a lookup that could not be
        // answered, however the keychain is configured.
        let refusals: [OSStatus] = [
            errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled, errSecNotAvailable, errSecNoSuchKeychain,
            errSecInvalidKeychain, errSecIO, errSecServiceNotAvailable, errSecMissingEntitlement, errSecDecode, errSecParam,
            errSecReadOnly, errSecDuplicateItem,
        ]
        for status in refusals {
            #expect(throws: SecretStoreError.self, "status \(status) must not read as absence") {
                try KeychainSecretStore.interpret(copyStatus: status, result: nil)
            }
        }
    }

    @Test(.failureMode("design/21", "the keychain is locked, or there is no UI session to unlock it"))
    func aLockedKeychainIsLockedNeverAbsent() {
        #expect(SecretStoreError(status: errSecInteractionNotAllowed) == .locked)
        #expect(SecretStoreError.locked.retryDecision == .retry)
    }

    @Test(.failureMode("design/21", "the user denies or cancels the system's access prompt"))
    func aDeniedOrCancelledPromptIsAuthenticationFailedNeverAbsent() {
        #expect(SecretStoreError(status: errSecAuthFailed) == .authenticationFailed)
        #expect(SecretStoreError(status: errSecUserCanceled) == .authenticationFailed)
        #expect(SecretStoreError.authenticationFailed.retryDecision == .stop, "asking again would just raise the prompt again")
    }

    @Test(.failureMode("design/21", "there is no keychain to open"))
    func aMissingKeychainIsUnavailableNeverAbsent() {
        #expect(SecretStoreError(status: errSecNoSuchKeychain) == .unavailable)
        #expect(SecretStoreError(status: errSecInvalidKeychain) == .unavailable)
        #expect(SecretStoreError(status: errSecNotAvailable) == .unavailable)
    }

    @Test func theDataProtectionKeychainIsNamedAndTheItemKeepsItsAccessibility() {
        let store = KeychainSecretStore(service: "com.example.app", accessGroup: "TEAM.group", accessibility: .whenUnlocked)
        #expect(store.keychain == .dataProtection)
        let identity = store.identity(of: "k")
        #expect(identity[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(identity[kSecAttrAccessGroup as String] as? String == "TEAM.group")
        #expect(identity[kSecAttrService as String] as? String == "com.example.app")
        #expect(identity[kSecAttrAccount as String] as? String == "k")
        let written = store.writtenAttributes(of: Data("v".utf8))
        #expect(written[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlocked as String)
        #expect(written[kSecValueData as String] as? Data == Data("v".utf8))
    }

    #if os(macOS)
    @Test(.failureMode("design/21", "the store is the login keychain (macOS)"))
    func theLoginKeychainStoreNamesNoDataProtectionKeychainAccessGroupOrAccessibility() {
        let store = KeychainSecretStore(loginKeychainService: "com.example.app")
        #expect(store.keychain == .login)
        #expect(store.accessGroup == nil)
        let identity = store.identity(of: "k")
        #expect(identity[kSecUseDataProtectionKeychain as String] == nil, "its absence is what selects the login keychain")
        #expect(identity[kSecAttrAccessGroup as String] == nil)
        #expect(Set(identity.keys) == [kSecClass as String, kSecAttrService as String, kSecAttrAccount as String])
        #expect(Set(store.writtenAttributes(of: Data("v".utf8)).keys) == [kSecValueData as String])
    }
    #endif

    @Test func theKeychainStoreDefaultsToAfterFirstUnlockThisDeviceOnly() {
        let store = KeychainSecretStore(service: "com.example.app")
        #expect(store.accessibility == .afterFirstUnlockThisDeviceOnly)
        #expect(store.accessGroup == nil)
        #expect(Set(KeychainSecretStore.Accessibility.allCases.map { $0.attribute as String }).count == 5)
    }
    #endif
}
