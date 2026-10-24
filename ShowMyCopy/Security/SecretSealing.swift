import Foundation

/// Encrypts and decrypts secrets, such as concealed clipboard entries, before they are written to disk.
///
/// Implementations must authenticate the data: `open` throws for data that was changed or sealed with another key.
/// `seal` and `open` never wait for a key: one whose key has to be fetched first (from the Keychain, which can wait
/// for the user to answer a prompt) throws `SecretSealingError.keyNotLoaded` until `loadKey()` fetched it.
protocol SecretSealing: Sendable {
    func seal(_ plaintext: Data) throws -> Data
    func open(_ sealed: Data) throws -> Data

    /// Gets the key ready, off the caller's actor, and says whether `seal` and `open` can use it now.
    func loadKey() async -> SealingKeyState
}

extension SecretSealing {
    /// A sealer that holds its key from the start is always ready.
    func loadKey() async -> SealingKeyState {
        .ready
    }
}

/// Whether a sealer's key can be used, after `SecretSealing.loadKey()`.
enum SealingKeyState: Equatable, Sendable {
    case ready
    /// Not now: the Mac is locked, or the Keychain may not ask the user. Worth trying again once the user is back
    /// at the unlocked Mac.
    case lockedOut
    /// Not this session: access was denied, or no key could be read or made. Asking again would show the same
    /// prompt again, so the next launch tries again.
    case unavailable
}
