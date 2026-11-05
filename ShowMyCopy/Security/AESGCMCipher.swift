import CryptoKit
import Foundation

/// AES-GCM from CryptoKit. With a 256-bit key and CryptoKit's random 12-byte nonce for every seal.
struct AESGCMCipher: AuthenticatedCipher {
    let key: SymmetricKey

    /// Returns `nonce (12 bytes) + ciphertext + tag (16 bytes)`.
    func seal(_ plaintext: Data, authenticating header: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: header)
        // `combined` is nil only for nonces that are not 12 bytes, which CryptoKit's own nonces never are.
        guard let combined = box.combined else { throw SecretSealingError.sealingFailed }
        return combined
    }

    func open(_ box: Data, authenticating header: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: box), using: key, authenticating: header)
    }
}
