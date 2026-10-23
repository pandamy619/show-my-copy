import Foundation

/// Why a secret could not be sealed or opened. Carries no secret data, so it is safe to log.
enum SecretSealingError: Error, Equatable, Sendable {
    /// The sealed data is empty, so it has no format version byte.
    case missingFormatVersion
    /// The data was sealed in a format this version of the app does not know.
    case unsupportedFormatVersion(UInt8)
    /// The data was changed, cut short or sealed with another key.
    case authenticationFailed
    /// The cipher could not seal the data.
    case sealingFailed
    /// A key had an unexpected length; keys are `SealingKey.byteCount` bytes.
    case invalidKeyLength(Int)
    /// The key could not be loaded or stored. Secrets should then stay in memory only.
    case keyUnavailable(SymmetricKeyStoreError)
}
