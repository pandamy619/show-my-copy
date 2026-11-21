import Foundation

/// What loading the saved accounts found.
enum CodeAccountsLoad: Equatable, Sendable {
    /// The saved accounts; empty when nothing was saved yet.
    case accounts([CodeAccount])
    /// The key is in a locked Keychain or may not ask the user now. Worth trying again when the user is back.
    case keyLockedOut
    /// There is no usable key this session: access was denied, or no key could be read or made.
    case keyUnavailable
    /// The file is there but cannot be opened or read: changed, cut short or sealed with another key. It is left
    /// as it is and never written over.
    case damaged
    /// The file was saved by a newer version of the app. Left as it is.
    case newerFormat
    /// The file could not be read now (a disk error). Left as it is; the next launch tries again.
    case unreadable
}

enum CodeAccountsSaveError: Error, Equatable, Sendable {
    /// The key is not ready (`SecretSealing.loadKey()`), so nothing can be sealed.
    case keyNotReady
    case sealingFailed
    case writeFailed
}

/// Where the accounts are saved. `SealedCodeAccountsFile` is the app's implementation; tests use a fake that fails
/// on demand. Both calls run off the caller's actor.
protocol CodeAccountsPersisting: Sendable {
    func load() async -> CodeAccountsLoad
    /// Replaces the saved accounts with `accounts`, as one change: after a failure the file holds what it held
    /// before. An empty list deletes the file.
    func save(_ accounts: [CodeAccount]) async throws(CodeAccountsSaveError)
}
