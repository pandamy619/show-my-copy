import Foundation
import Observation

/// State of the history window: the search query and the selected row.
@MainActor
@Observable
final class HistoryWindowModel {
    enum Direction: Sendable {
        case up
        case down
    }

    let history: ClipboardHistory

    var query = "" {
        didSet {
            if query != oldValue {
                selection = 0
            }
        }
    }

    /// Raw selection. Read `selectedIndex`, which keeps it inside the current list.
    private var selection = 0

    /// Changes every time the window is shown, so the view can move focus to the search field.
    private(set) var presentationCount = 0

    init(history: ClipboardHistory) {
        self.history = history
    }

    /// Entries that match the query, newest first.
    var items: [ClipboardEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return history.entries
        }
        return history.entries.filter { Self.entry($0, matches: needle) }
    }

    /// The newest entry is what is on the clipboard now.
    var currentEntryID: ClipboardEntry.ID? {
        history.entries.first?.id
    }

    var selectedIndex: Int? {
        Self.clamped(selection, count: items.count)
    }

    /// The selected index within an already filtered list, so callers don't filter the history twice.
    func selectedIndex(in items: [ClipboardEntry]) -> Int? {
        Self.clamped(selection, count: items.count)
    }

    var selectedEntry: ClipboardEntry? {
        let items = items
        guard let index = Self.clamped(selection, count: items.count) else {
            return nil
        }
        return items[index]
    }

    func moveSelection(_ direction: Direction) {
        let count = items.count
        guard let current = Self.clamped(selection, count: count) else {
            selection = 0
            return
        }
        switch direction {
        case .up:
            selection = max(current - 1, 0)
        case .down:
            selection = min(current + 1, count - 1)
        }
    }

    func select(id: ClipboardEntry.ID) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            selection = index
        }
    }

    /// Clears the search and selects the first row. Called each time the window is shown.
    func prepareForPresentation() {
        query = ""
        selection = 0
        presentationCount += 1
    }

    /// Only the beginning of each entry is searched, so typing stays fast with long entries.
    nonisolated static let searchedCharacters = 10_000

    /// Case- and diacritic-insensitive match against the text and the source app name.
    nonisolated static func entry(_ entry: ClipboardEntry, matches needle: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if entry.text.prefix(searchedCharacters).range(of: needle, options: options) != nil {
            return true
        }
        guard let appName = entry.sourceApp?.name else {
            return false
        }
        return appName.range(of: needle, options: options) != nil
    }

    private static func clamped(_ index: Int, count: Int) -> Int? {
        guard count > 0 else {
            return nil
        }
        return min(max(index, 0), count - 1)
    }
}
