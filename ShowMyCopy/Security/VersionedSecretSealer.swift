import Foundation

/// Seals secrets as `[format version] + cipher output`.
///
/// The leading byte lets a later version change the cipher or the key without guessing what old data is. Data with
/// an unknown version is rejected rather than tried with the current cipher. The version byte is also passed to the
/// cipher as authenticated data, so changing it is detected even if a later format would accept the new value.
struct VersionedSecretSealer<Cipher: AuthenticatedCipher>: SecretSealing {
    /// Version 1: AES-256-GCM, `nonce (12 bytes) + ciphertext + tag (16 bytes)`, header authenticated.
    static var formatVersion: UInt8 { 1 }

    let cipher: Cipher

    func seal(_ plaintext: Data) throws -> Data {
        let header = Data([Self.formatVersion])
        let box: Data
        do {
            box = try cipher.seal(plaintext, authenticating: header)
        } catch {
            throw SecretSealingError.sealingFailed
        }
        return header + box
    }

    func open(_ sealed: Data) throws -> Data {
        guard let version = sealed.first else { throw SecretSealingError.missingFormatVersion }
        guard version == Self.formatVersion else { throw SecretSealingError.unsupportedFormatVersion(version) }
        // Rebased copy: `sealed` may be a slice whose indices do not start at zero.
        let box = Data(sealed.dropFirst())
        do {
            return try cipher.open(box, authenticating: Data([version]))
        } catch {
            // The cipher's own error says nothing more useful, and every failure here means the same thing to
            // the caller: this data cannot be trusted or read.
            throw SecretSealingError.authenticationFailed
        }
    }
}
