import Foundation

/// The rows the window lists, entries and codes together (`HistoryRowItem`).
extension HistoryWindowModel {
    /// Whether there are accounts to show, so the window offers the button that shows them.
    var hasCodes: Bool {
        !(codes?.accounts.isEmpty ?? true)
    }

    /// The accounts whose codes match the query, by issuer and name, never by the code: first in the list, under
    /// the search bar. Empty without accounts and while the section is hidden (`showsCodes`).
    var codeRows: [CodeAccount] {
        guard showsCodes, let codes, !codes.accounts.isEmpty else {
            return []
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return codes.accounts
        }
        let foldedQuery = SearchKey.fold(needle)
        return codes.accounts.filter { SearchKey.key(SearchKey.fold($0.displayName), contains: foldedQuery) }
    }

    /// Every listed row in the order the window shows them: the codes when shown, the clipboard row, the pinned
    /// entries, then the history. The arrow keys move through these.
    var rows: [HistoryRowItem] {
        let sections = sections
        var rows: [HistoryRowItem] = codeRows.map(HistoryRowItem.code)
        if let current = sections.current {
            rows.append(.entry(current))
        }
        rows += sections.pinned.map(HistoryRowItem.entry)
        rows += sections.history.map(HistoryRowItem.entry)
        return rows
    }

    /// Whether the window lists any rows. False for an empty history without codes and for a search with no
    /// matches: then the window shrinks to the search bar and a one-line message. Observable, like `items`.
    var showsEntries: Bool {
        !rows.isEmpty
    }
}
