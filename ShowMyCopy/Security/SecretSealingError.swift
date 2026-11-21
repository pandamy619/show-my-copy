import Foundation

/// Why a secret could not be sealed or opened. Carries no secret data, so it is safe to log.
enum SecretSealingError: Error, Equatable, Sendable {
    /// The sealed data is empty, so it has no format version byte.
    case missingFormatVersion
    /// The data was sealed in a format this version of the app does not know and no version wrote: damaged.
    case unsupportedFormatVersion(UInt8)
    /// The data was sealed by a newer version of the app, in a format this one does not know yet. It may well be
    /// fine, so it must be left alone for that version, never deleted.
    case newerFormatVersion(UInt8)
    /// The data was changed, cut short or sealed with another key.
    case authenticationFailed
    /// The cipher could not seal the data.
    case sealingFailed
    /// A key had an unexpected length; keys are `SealingKey.byteCount` bytes.
    case invalidKeyLength(Int)
    /// The key could not be loaded or stored. Secrets should then stay in memory only.
    case keyUnavailable(SymmetricKeyStoreError)
    /// The key has not been fetched yet (`SecretSealing.loadKey()`); it is fetched off the main thread.
    case keyNotLoaded

    /// Whether the key store said no for now only: the Mac is locked or the Keychain may not ask or is not available
    /// right now. Worth asking again this session, when the user is back at the unlocked Mac.
    var isTemporary: Bool {
        switch self {
        case .keyUnavailable(.interactionNotAllowed), .keyUnavailable(.notAvailableNow):
            true
        default:
            false
        }
    }

    /// Whether the key could not be used, as opposed to the sealed data being wrong. Data that could not be opened
    /// for want of a key may open later, so it must not be deleted for this.
    var isAboutTheKey: Bool {
        switch self {
        case .keyUnavailable, .keyNotLoaded, .invalidKeyLength:
            true
        case .missingFormatVersion, .unsupportedFormatVersion, .newerFormatVersion, .authenticationFailed,
            .sealingFailed:
            false
        }
    }
}
