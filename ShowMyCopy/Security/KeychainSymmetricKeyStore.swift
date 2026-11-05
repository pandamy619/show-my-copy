import Foundation
import Security

/// Keeps the history key as a generic password item in the Keychain.
///
/// Which keychain (decided for Show My Copy: sandboxed, no keychain entitlements, ad-hoc or Developer ID signed):
///
/// 1. The data protection keychain first (`kSecUseDataProtectionKeychain`), with
///    `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and `kSecAttrSynchronizable: false`: the key is never synced
///    to iCloud, never restored from a backup onto another device, and readable only while the Mac is unlocked.
///    It never shows a prompt. But macOS gives a program data protection keychain access only through keychain
///    access groups from its entitlements (`keychain-access-groups` or the app identifier), authorized by a
///    provisioning profile (Apple TN3137). Show My Copy has neither, and adding one would be a new entitlement
///    that `scripts/check_security.py` rejects, so today this fails with `errSecMissingEntitlement`.
/// 2. Then the file-based login keychain, which sandboxed apps may use without any entitlement. Its items are
///    protected by an access control list that trusts the app that created them, identified by its code signature.
///    A build with the same signing identity (for example Developer ID) reads the key without a prompt. After the
///    signature changes, for example every ad-hoc rebuild, macOS asks "Show My Copy wants to use your confidential
///    information stored in … in your keychain"; while it asks, the calling thread waits, so create the sealer off
///    the main thread. If the user denies, loading fails with `.accessDenied` and no new key is made. This
///    keychain cannot sync, and the accessibility attribute does not apply to it, so neither is set; but the login
///    keychain file is in Time Machine backups and Migration Assistant can copy it to a new Mac.
///
/// Only `errSecMissingEntitlement` moves on to the next keychain (see `SealingKey.loadOrCreate`), so a key that
/// exists but cannot be read now is never replaced by a new one elsewhere. Should the app gain a keychain access
/// group later, it starts with a new key in the data protection keychain and old sealed data can no longer be
/// opened, which the storage layer handles by dropping it.
struct KeychainSymmetricKeyStore: SymmetricKeyStore, Sendable {
    enum Backend: Sendable {
        case dataProtection
        case fileBased
    }

    let service: String
    let account: String
    let backend: Backend

    /// The stores the app tries, in order.
    static func stores(service: String, account: String) -> [KeychainSymmetricKeyStore] {
        [
            KeychainSymmetricKeyStore(service: service, account: account, backend: .dataProtection),
            KeychainSymmetricKeyStore(service: service, account: account, backend: .fileBased),
        ]
    }

    func loadKey() throws(SymmetricKeyStoreError) -> Data? {
        var query = itemQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw .unexpectedItemData }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw Self.error(for: status)
        }
    }

    func addKey(_ key: Data) throws(SymmetricKeyStoreError) {
        var attributes = itemQuery()
        attributes[kSecValueData as String] = key
        // Shown in Keychain Access, so a person who finds the item knows what it is.
        attributes[kSecAttrLabel as String] = "Show My Copy history key"
        attributes[kSecAttrDescription as String] = "encryption key"
        if backend == .dataProtection {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw Self.error(for: status) }
    }

    /// Removes the key; succeeds when there is none. Everything sealed with it can no longer be opened.
    func deleteKey() throws(SymmetricKeyStoreError) {
        let status = SecItemDelete(itemQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(for: status) }
    }

    private func itemQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if backend == .dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrSynchronizable as String] = false
        }
        return query
    }

    private static func error(for status: OSStatus) -> SymmetricKeyStoreError {
        switch status {
        case errSecMissingEntitlement: .missingEntitlement
        case errSecDuplicateItem: .duplicateItem
        case errSecInteractionNotAllowed: .interactionNotAllowed
        case errSecAuthFailed, errSecUserCanceled: .accessDenied
        default: .unexpectedStatus(status)
        }
    }
}
