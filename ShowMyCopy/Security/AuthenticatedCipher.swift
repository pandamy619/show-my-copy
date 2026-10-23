import Foundation

/// An authenticated cipher (AEAD) with its key, such as AES-GCM. The real one lives in `Platform/Security` because
/// CryptoKit exists only on Apple platforms; the framing around it is plain code that is tested everywhere.
protocol AuthenticatedCipher: Sendable {
    /// Encrypts `plaintext` and authenticates it together with `header`, which is not encrypted.
    func seal(_ plaintext: Data, authenticating header: Data) throws -> Data
    /// Throws when `box` or `header` differ from what was sealed, or when another key sealed it.
    func open(_ box: Data, authenticating header: Data) throws -> Data
}
