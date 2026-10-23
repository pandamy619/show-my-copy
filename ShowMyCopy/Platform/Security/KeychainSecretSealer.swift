import CryptoKit
import Foundation
import os

/// Seals secrets with AES-256-GCM under a key kept in the Keychain (see `KeychainSymmetricKeyStore` for which
/// keychain and why). Sealed data is `[format version 1] + nonce + ciphertext + tag`, with the version byte
/// authenticated too.
///
/// Holds only an immutable key, so one instance can be shared across threads and actors.
final class KeychainSecretSealer: SecretSealing {
    static let service = "com.pandamy619.ShowMyCopy.history-key"
    static let account = "history-encryption-key"

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pandamy619.ShowMyCopy", category: "security")

    private let sealer: VersionedSecretSealer<AESGCMCipher>

    /// Loads the history key from the Keychain, or creates and stores one on first use.
    ///
    /// Throws `SecretSealingError` (usually `.keyUnavailable`) when there is no usable key; keep secrets in memory
    /// only then. May wait for the user to answer a Keychain prompt (file-based keychain after the app's code
    /// signature changed), so call it off the main thread.
    convenience init() throws(SecretSealingError) {
        try self.init(keyStores: KeychainSymmetricKeyStore.stores(service: Self.service, account: Self.account))
    }

    init(keyStores: [any SymmetricKeyStore]) throws(SecretSealingError) {
        let keyData: Data
        do {
            keyData = try SealingKey.loadOrCreate(in: keyStores, generate: Self.newKeyData)
        } catch {
            // The error holds only status codes and lengths, never key material.
            Self.logger.error("History encryption key unavailable: \(String(describing: error), privacy: .public)")
            throw error
        }
        sealer = VersionedSecretSealer(cipher: AESGCMCipher(key: SymmetricKey(data: keyData)))
    }

    func seal(_ plaintext: Data) throws -> Data {
        try sealer.seal(plaintext)
    }

    func open(_ sealed: Data) throws -> Data {
        try sealer.open(sealed)
    }

    private static func newKeyData() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
}
