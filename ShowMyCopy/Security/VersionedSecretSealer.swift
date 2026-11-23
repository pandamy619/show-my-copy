import Foundation

/// Seals secrets as `[format version] + cipher output`.
///
/// The leading byte lets a later version change the cipher or the key without guessing what old data is. Data with
/// an unknown version is rejected rather than tried with the current cipher: a version above the current one was
/// written by a newer app (`newerFormatVersion`), so the caller leaves the data for it; one below the first was
/// written by nothing and is damaged. The version byte is passed to the cipher as authenticated data, so changing it
/// is detected even if a later format would accept the new value.
///
/// - Version 1 (0.1.0 and 0.2.0): AES-256-GCM, `nonce (12 bytes) + ciphertext + tag (16 bytes)`, the version byte
///   authenticated. Still opened, with any context: a password saved by those versions stays readable until it
///   expires, and the accounts file until it is next written, which seals it in version 2.
/// - Version 2: the same, with the `SealingContext` authenticated after the version byte, so the data opens only in
///   the record or file it was sealed for. Everything is sealed in this version.
struct VersionedSecretSealer<Cipher: AuthenticatedCipher>: SecretSealing {
    static var formatVersion: UInt8 { 2 }
    /// The oldest version a build still opens.
    static var firstFormatVersion: UInt8 { 1 }
    /// The version before the context was authenticated.
    private static var unboundFormatVersion: UInt8 { 1 }

    let cipher: Cipher

    func seal(_ plaintext: Data, boundTo context: SealingContext) throws -> Data {
        let header = Data([Self.formatVersion])
        let box: Data
        do {
            box = try cipher.seal(plaintext, authenticating: header + context.bytes)
        } catch {
            throw SecretSealingError.sealingFailed
        }
        return header + box
    }

    func open(_ sealed: Data, boundTo context: SealingContext) throws -> Data {
        guard let version = sealed.first else { throw SecretSealingError.missingFormatVersion }
        guard version <= Self.formatVersion else { throw SecretSealingError.newerFormatVersion(version) }
        guard version >= Self.firstFormatVersion else { throw SecretSealingError.unsupportedFormatVersion(version) }
        let authenticated = version == Self.unboundFormatVersion ? Data([version]) : Data([version]) + context.bytes
        // Rebased copy: `sealed` may be a slice whose indices do not start at zero.
        let box = Data(sealed.dropFirst())
        do {
            return try cipher.open(box, authenticating: authenticated)
        } catch {
            // The cipher's own error says nothing more useful, and every failure here means the same thing to
            // the caller: this data cannot be trusted or read.
            throw SecretSealingError.authenticationFailed
        }
    }
}
