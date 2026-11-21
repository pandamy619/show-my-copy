import Foundation

/// One row of the history window: a history entry, or an account whose code the window shows. The arrow keys walk
/// the rows of both kinds in the order the window lists them, and the selection is kept by the row's ID, which is
/// unique across both kinds (both are UUIDs made by this app).
enum HistoryRowItem: Identifiable, Equatable, Sendable {
    case entry(ClipboardEntry)
    case code(CodeAccount)

    var id: UUID {
        switch self {
        case .entry(let entry):
            entry.id
        case .code(let account):
            account.id
        }
    }

    var entry: ClipboardEntry? {
        if case .entry(let entry) = self {
            return entry
        }
        return nil
    }

    var code: CodeAccount? {
        if case .code(let account) = self {
            return account
        }
        return nil
    }
}
