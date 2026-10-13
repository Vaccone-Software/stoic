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
/// - Items use the data-protection keychain on every platform, so a Mac app
///   behaves like an iOS one: no access prompts, and removed with the app.
///   That keychain needs a signed app with an application identifier; an
///   unsigned command-line tool gets ``SecretStoreError/missingEntitlement``.
/// - ``Accessibility`` says when the item can be read. The default,
///   ``Accessibility/afterFirstUnlockThisDeviceOnly``, lets background work
///   read it after the first unlock since boot (a background task needs this),
///   keeps it out of backups and iCloud, and leaves it unreadable before
///   that first unlock. `set` applies the store's accessibility to an item
///   written earlier with another.
/// - The calls are synchronous. The Keychain can block, so call off the
///   main actor.
public struct KeychainSecretStore: SecretStore {
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
    public let accessGroup: String?
    public let accessibility: Accessibility

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
    }

    public func get(_ key: String) throws(SecretStoreError) -> Data? {
        guard !key.isEmpty else { throw .invalidKey }
        var query = identity(of: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = unsafe SecItemCopyMatching(query as CFDictionary, &result)
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
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: accessibility.attribute,
        ]
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
    private func identity(of key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
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
        case errSecNotAvailable, errSecIO, errSecServiceNotAvailable: self = .unavailable
        default: self = .other(status: status)
        }
    }
}
#endif
