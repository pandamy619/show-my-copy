import Foundation

/// What a sealed secret belongs to: the history record or the file it is saved in.
///
/// The context is passed to the cipher as authenticated data next to the format version, so a ciphertext opens only
/// where it was sealed: a saved password copied into another record, or into the accounts file, fails to open as
/// changed data would. It is not stored with the data; both sides know it from where the data is.
struct SealingContext: Equatable, Sendable {
    /// The bytes the cipher authenticates: a label, a zero byte and what identifies the place.
    let bytes: Data

    private init(label: String, identity: Data = Data()) {
        bytes = Data(label.utf8) + Data([0]) + identity
    }

    /// A password in the history record with `id`.
    static func historyEntry(_ id: UUID) -> SealingContext {
        SealingContext(label: "history-entry", identity: withUnsafeBytes(of: id.uuid) { Data($0) })
    }

    /// The one-time code accounts file (`SealedCodeAccountsFile`).
    static let codeAccounts = SealingContext(label: "code-accounts")
}
