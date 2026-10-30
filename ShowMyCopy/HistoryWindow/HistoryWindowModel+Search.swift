import Foundation

extension HistoryWindowModel {
    /// Case- and diacritic-insensitive match against the text and the source app name, using the keys folded when
    /// the entry was made. `foldedQuery` must be folded with `SearchKey.fold(_:)`. A concealed entry matches only by
    /// its source app name, so typing part of a password does not reveal which entry holds it.
    nonisolated static func entry(_ entry: ClipboardEntry, matches foldedQuery: String) -> Bool {
        if !entry.isConcealed, SearchKey.key(entry.searchKey, contains: foldedQuery) {
            return true
        }
        return SearchKey.key(entry.sourceAppSearchKey, contains: foldedQuery)
    }
}
