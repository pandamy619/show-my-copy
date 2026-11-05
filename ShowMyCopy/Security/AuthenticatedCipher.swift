import Foundation

/// An authenticated cipher (AEAD) with its key: AES-GCM in the app (`AESGCMCipher`). The framing around it
/// (`VersionedSecretSealer`) is plain code, tested with a fake cipher.
protocol AuthenticatedCipher: Sendable {
    /// Encrypts `plaintext` and authenticates it together with `header`, which is not encrypted.
    func seal(_ plaintext: Data, authenticating header: Data) throws -> Data
    /// Throws when `box` or `header` differ from what was sealed, or when another key sealed it.
    func open(_ box: Data, authenticating header: Data) throws -> Data
}
