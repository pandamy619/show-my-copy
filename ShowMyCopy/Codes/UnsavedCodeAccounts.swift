import Foundation

/// Where accounts go when Application Support cannot be found: nowhere. They are kept in memory for the session,
/// and Settings say so (`CodeAccountStore.Availability.unavailable(.unreadable)`).
struct UnsavedCodeAccounts: CodeAccountsPersisting {
    func load() async -> CodeAccountsLoad {
        .unreadable
    }

    func save(_ accounts: [CodeAccount]) async throws(CodeAccountsSaveError) {
        throw .writeFailed
    }
}
