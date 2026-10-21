import Foundation

/// Text prepared for search: case and diacritics are folded away, so "Café" and "CAFE" give the same key.
///
/// Entries keep their keys from the time they are recorded (`ClipboardEntry.searchKey`), so typing in the history
/// window folds only the query, not every entry on every keystroke.
enum SearchKey {
    /// Only the beginning of each entry is searched, so recording and typing stay fast with long entries.
    static let searchedCharacters = 10_000

    static func fold(_ text: some StringProtocol) -> String {
        String(text).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The key for the start of the content's text, or nil for content without text.
    static func text(of content: ClipboardContent) -> String? {
        content.text.map { fold($0.prefix(searchedCharacters)) }
    }

    /// The key for the app's name, or nil when the app or its name is unknown.
    static func appName(of app: SourceApp?) -> String? {
        app?.name.map { fold($0) }
    }

    /// Whether `key` contains `foldedQuery`, which must be folded with `fold(_:)`.
    static func key(_ key: String?, contains foldedQuery: String) -> Bool {
        guard let key else {
            return false
        }
        return key.contains(foldedQuery)
    }
}
