#if canImport(Security)
public import Foundation
internal import Security

/// A ``SecretStore`` in the Keychain: one generic password per key,
/// `kSecClassGenericPassword`, the key as its account and `service` as its
/// service.
///
///     let secrets = KeychainSecretStore(service: "com.example.app")
///     try secrets.set(Data(token.utf8), for: "api-token")
///
/// - By default items use the data-protection keychain on every platform, so a
///   Mac app behaves like an iOS one: no access prompts, and removed with the
///   app. That keychain needs a signed app with an application identifier; an
///   unsigned command-line tool, or a Developer ID app without an
///   `application-identifier` entitlement, gets
///   ``SecretStoreError/missingEntitlement``. On macOS,
///   ``init(loginKeychainService:)`` uses the login keychain instead (below).
/// - ``Accessibility`` says when the item can be read. The default,
///   ``Accessibility/afterFirstUnlockThisDeviceOnly``, lets background work
///   read it after the first unlock since boot (a background task needs this),
///   keeps it out of backups and iCloud, and leaves it unreadable before
///   that first unlock. `set` applies the store's accessibility to an item
///   written earlier with another.
/// - The calls are synchronous. The Keychain can block, so call off the
///   main actor.
///
/// ## The login keychain (macOS)
///
/// `KeychainSecretStore(loginKeychainService:)` leaves out
/// `kSecUseDataProtectionKeychain`, so items go to the user's default
/// (file-based, "login") keychain, which an app signed without an
/// application-identifier entitlement can use. What that changes:
///
/// - **Items outlive the app.** Deleting or reinstalling the app does not
///   remove them; they stay until ``delete(_:)`` or the user removes them in
///   Keychain Access.
/// - **They travel.** The login keychain is copied by Time Machine (its items
///   are encrypted under the login password, so the copy is as safe as the
///   password) and moved to a new Mac by Migration Assistant. Nothing about
///   the item says "this device only": ``Accessibility`` and `accessGroup`
///   belong to the data-protection keychain and are not applied here.
/// - **Access follows the code signature.** The system lets the app that
///   created an item read it without asking, and prompts for any other
///   (a development build signed differently, an app re-signed with another
///   identity). The prompt is the system's; if the user denies it, or
///   cancels, the call throws ``SecretStoreError/authenticationFailed``. The
///   item is not gone.
/// - **A locked keychain is not an empty one.** While the user is logged out
///   of the keychain (it locked on sleep, say) a call throws
///   ``SecretStoreError/locked``; with no UI session (over SSH) the same.
///   `get` returns `nil` only for `errSecItemNotFound`, never for any of
///   these, so a caller that treats `nil` as "the secret was never made"
///   cannot be misled by a locked or refusing keychain.
public struct KeychainSecretStore: SecretStore {
    /// Which keychain holds the items.
    public enum Keychain: Sendable, Hashable {
        /// The data-protection keychain: iOS's, and on macOS the one an app
        /// with an application identifier reaches (`kSecUseDataProtectionKeychain`).
        case dataProtection
        #if os(macOS)
        /// The user's default file-based (login) keychain, which needs no
        /// application-identifier entitlement. See the type's documentation
        /// for what that changes.
        case login
        #endif
    }

    /// When a stored secret can be read.
    public enum Accessibility: Sendable, Hashable, CaseIterable {
        case whenUnlocked
        case whenUnlockedThisDeviceOnly
        case afterFirstUnlock
        case afterFirstUnlockThisDeviceOnly
        /// Only while a passcode is set; deleted if it is removed.
        case whenPasscodeSetThisDeviceOnly

        var attribute: CFString {
            switch self {
            case .whenUnlocked: kSecAttrAccessibleWhenUnlocked
            case .whenUnlockedThisDeviceOnly: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            case .afterFirstUnlock: kSecAttrAccessibleAfterFirstUnlock
            case .afterFirstUnlockThisDeviceOnly: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            case .whenPasscodeSetThisDeviceOnly: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
            }
        }
    }

    public let service: String
    /// The keychain access group; unused by the login keychain.
    public let accessGroup: String?
    /// When the secrets can be read; unused by the login keychain.
    public let accessibility: Accessibility
    /// Which keychain holds the items.
    public let keychain: Keychain

    /// - Parameters:
    ///   - service: Names this app's secrets; use the bundle identifier.
    ///   - accessGroup: A keychain access group to share with other apps, or `nil` for the app's own.
    ///   - accessibility: When the secrets can be read.
    public init(
        service: String,
        accessGroup: String? = nil,
        accessibility: Accessibility = .afterFirstUnlockThisDeviceOnly
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.accessibility = accessibility
        self.keychain = .dataProtection
    }

    #if os(macOS)
    /// A store in the login keychain, for an app that cannot use the
    /// data-protection keychain (a Developer ID app with no application
    /// identifier gets `.missingEntitlement` from it). The type's
    /// documentation says what differs: items persist across reinstalls and
    /// are backed up and migrated, and access follows the code signature.
    ///
    /// - Parameter service: Names this app's secrets; use the bundle identifier.
    public init(loginKeychainService service: String) {
        self.service = service
        self.accessGroup = nil
        self.accessibility = .afterFirstUnlockThisDeviceOnly
        self.keychain = .login
    }
    #endif

    public func get(_ key: String) throws(SecretStoreError) -> Data? {
        guard !key.isEmpty else { throw .invalidKey }
        var query = identity(of: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = unsafe SecItemCopyMatching(query as CFDictionary, &result)
        return try Self.interpret(copyStatus: status, result: result)
    }

    /// What the answer to a lookup means. Only `errSecItemNotFound` is
    /// "there is nothing under that key"; a locked keychain, a refused or
    /// cancelled prompt, a missing keychain and every status Stoic does not
    /// know throw, so none of them can be mistaken for an absent secret.
    static func interpret(copyStatus status: OSStatus, result: CFTypeRef?) throws(SecretStoreError) -> Data? {
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw .corrupted }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw SecretStoreError(status: status)
        }
    }

    public func set(_ value: Data, for key: String) throws(SecretStoreError) {
        guard !key.isEmpty else { throw .invalidKey }
        guard !value.isEmpty else { throw .invalidValue }
        let identity = identity(of: key)
        let attributes = writtenAttributes(of: value)
        // Update first: an existing item keeps its identity. If it vanishes
        // between the update and the add (another process deleted it), the
        // add is the right call, and one more pass settles any race on it.
        for _ in 0..<2 {
            var status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(identity.merging(attributes) { $1 } as CFDictionary, nil)
            }
            switch status {
            case errSecSuccess: return
            case errSecDuplicateItem: continue
            default: throw SecretStoreError(status: status)
            }
        }
        throw .unavailable
    }

    public func delete(_ key: String) throws(SecretStoreError) {
        guard !key.isEmpty else { throw .invalidKey }
        let status = SecItemDelete(identity(of: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError(status: status) }
    }

    /// The attributes that name one item.
    func identity(of key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        switch keychain {
        case .dataProtection:
            query[kSecUseDataProtectionKeychain as String] = true
            if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        #if os(macOS)
        case .login:
            // No `kSecUseDataProtectionKeychain`: the default (login) keychain.
            // No access group either: the file-based keychain has none.
            break
        #endif
        }
        return query
    }

    /// What `set` stores: the value, and when it can be read, which only the
    /// data-protection keychain has (the login keychain's items are readable
    /// whenever it is unlocked).
    func writtenAttributes(of value: Data) -> [String: Any] {
        var attributes: [String: Any] = [kSecValueData as String: value]
        if keychain == .dataProtection { attributes[kSecAttrAccessible as String] = accessibility.attribute }
        return attributes
    }
}

extension SecretStoreError {
    /// Maps a Keychain `OSStatus`. Only the status number is kept: the
    /// system's message text can quote the service or account.
    init(status: OSStatus) {
        switch status {
        case errSecInteractionNotAllowed: self = .locked
        case errSecAuthFailed, errSecUserCanceled: self = .authenticationFailed
        case errSecMissingEntitlement: self = .missingEntitlement
        // No default keychain, or one that cannot be opened: the login
        // keychain's way of saying it cannot be asked, not that it is empty.
        case errSecNotAvailable, errSecIO, errSecServiceNotAvailable, errSecNoSuchKeychain, errSecInvalidKeychain:
            self = .unavailable
        default: self = .other(status: status)
        }
    }
}
#endif
