import Foundation

/// Why a key store could not load or add the key. Carries no key material.
enum SymmetricKeyStoreError: Error, Equatable, Sendable {
    /// This build may not use this store, for example the data protection keychain without a keychain access group.
    case missingEntitlement
    /// A key is already stored; `addKey` never overwrites it.
    case duplicateItem
    /// The store needs the Mac unlocked or would have to ask the user, and asking is not allowed.
    case interactionNotAllowed
    /// The user or the system refused access to the stored key.
    case accessDenied
    /// The store returned something that is not key data.
    case unexpectedItemData
    /// Any other failure, with the store's status code.
    case unexpectedStatus(Int32)
}

/// Keeps one raw symmetric key, such as a Keychain item. Raw `Data` keeps this protocol free of CryptoKit, so the
/// logic that decides when to create a key compiles and is tested everywhere.
protocol SymmetricKeyStore {
    /// The stored key, or `nil` when there is none.
    func loadKey() throws(SymmetricKeyStoreError) -> Data?
    /// Stores `key`. Throws `.duplicateItem` when a key is already stored, and never replaces it.
    func addKey(_ key: Data) throws(SymmetricKeyStoreError)
}
