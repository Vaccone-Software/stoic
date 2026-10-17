#if STOIC_CRYPTO
internal import Foundation
public import StoicApple
public import StoicSealed

/// A ``KeyCustody`` over a ``SecretStore``: the Keychain (or any secret store)
/// as the place a ``Keyring`` is kept, which is not beside the data it protects.
///
///     let custody = SecretStoreCustody(KeychainSecretStore(service: "com.example.app"))
///     let ring = try Keyring.open(name: "app.keyring", custody: custody, ifMissing: .create).keyring
///
/// `StoicSealed` does not know the Keychain, and `StoicApple` does not know
/// sealing, so this small library is where they meet: an app that wants both
/// adds this product and writes no adapter. Which keychain, and what each
/// gives (backups, accessibility, a differently signed build), is chosen by
/// the `SecretStore` passed in (design/24, "Which keychain").
///
/// ## What "absent" means
///
/// The one fact a custody must never get wrong is **`nil` means definitely
/// absent**: a caller that sees it may create a new keyring, which orphans
/// everything sealed under the old one. ``SecretStore/get(_:)`` returns `nil`
/// only for `errSecItemNotFound` (design/21), and every other answer throws,
/// so this adapter returns `nil` for exactly that and maps every refusal to an
/// error that says **the item may exist**:
///
/// | ``SecretStoreError``                            | ``CustodyError``                        |
/// | ----------------------------------------------- | --------------------------------------- |
/// | ``SecretStoreError/locked``                     | `.unavailable(.locked)`                 |
/// | ``SecretStoreError/authenticationFailed``       | `.unavailable(.accessDenied)`           |
/// | ``SecretStoreError/missingEntitlement``         | `.unavailable(.accessDenied)`           |
/// | ``SecretStoreError/unavailable``                | `.unavailable(.serviceUnavailable)`     |
/// | ``SecretStoreError/invalidKey``                 | `.invalidName`                          |
/// | ``SecretStoreError/invalidValue``               | `.invalidName`                          |
/// | ``SecretStoreError/corrupted``                  | `.other(code: -1)`                      |
/// | ``SecretStoreError/other(status:)``             | `.other(code: status)`                  |
///
/// Everything but the two invalid-argument cases is a ``CustodyError`` whose
/// ``CustodyError/itemMayExist`` is `true`, so a keychain that is locked, that
/// the user refused, or that the app has no entitlement for is never read as
/// "the keyring is not there". (``SecretStoreError/invalidValue`` is an empty
/// value, which a keyring never is; it maps to `.invalidName` as design/24
/// always has.)
///
/// ## What it adds
///
/// Nothing else: no retry, no cache, no logging. `store` replaces and is
/// atomic if the secret store's `set` is (a keychain update is), `delete` of an
/// absent name succeeds if the store's does, and a call blocks as long as the
/// secret store does (the Keychain can wait for a user): call it off the main
/// actor.
public struct SecretStoreCustody: KeyCustody {
    /// The secret store the keyring is kept in.
    public let secrets: any SecretStore

    public init(_ secrets: any SecretStore) {
        self.secrets = secrets
    }

    public func load(name: String) throws(CustodyError) -> [UInt8]? {
        do throws(SecretStoreError) {
            return try secrets.get(name).map { [UInt8]($0) }
        } catch {
            throw CustodyError(error)
        }
    }

    public func store(_ bytes: [UInt8], name: String) throws(CustodyError) {
        do throws(SecretStoreError) {
            try secrets.set(Data(bytes), for: name)
        } catch {
            throw CustodyError(error)
        }
    }

    public func delete(name: String) throws(CustodyError) {
        do throws(SecretStoreError) {
            try secrets.delete(name)
        } catch {
            throw CustodyError(error)
        }
    }
}

extension CustodyError {
    /// Nothing a secret store refuses is "absent": every case but an invalid
    /// key or value means the item may exist (table on ``SecretStoreCustody``).
    init(_ error: SecretStoreError) {
        switch error {
        case .locked: self = .unavailable(.locked)
        case .authenticationFailed, .missingEntitlement: self = .unavailable(.accessDenied)
        case .unavailable: self = .unavailable(.serviceUnavailable)
        case .invalidKey, .invalidValue: self = .invalidName
        case .corrupted: self = .other(code: -1)
        case .other(let status): self = .other(code: Int(status))
        }
    }
}
#endif
