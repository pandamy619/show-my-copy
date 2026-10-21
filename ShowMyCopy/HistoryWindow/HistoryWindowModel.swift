import Foundation
import Observation

/// State of the history window: the search query and the selected entry.
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
                selectFirst()
            }
        }
    }

    /// The selected entry. It is kept by ID, so the selection stays on the same entry when a copy arrives or an
    /// entry moves to the top while the window is open. Read `selectedIndex`, which finds its row.
    private var selectedID: ClipboardEntry.ID?

    /// The row of the selected entry when it was selected. Used when there is no selected entry or it is gone,
    /// so the selection stays near where it was instead of jumping to the top.
    private var selectedRow = 0

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

    /// The entry whose text is on the clipboard now. Nil after a copy that was not recorded, such as a password
    /// or an image: then the newest entry is no longer on the clipboard and the window shows no current entry.
    var currentEntryID: ClipboardEntry.ID? {
        history.currentEntryID
    }

    var selectedIndex: Int? {
        selectedIndex(in: items)
    }

    /// The selected index within an already filtered list, so callers don't filter the history twice.
    func selectedIndex(in items: [ClipboardEntry]) -> Int? {
        if let selectedID, let index = items.firstIndex(where: { $0.id == selectedID }) {
            return index
        }
        return Self.clamped(selectedRow, count: items.count)
    }

    var selectedEntry: ClipboardEntry? {
        let items = items
        guard let index = selectedIndex(in: items) else {
            return nil
        }
        return items[index]
    }

    func moveSelection(_ direction: Direction) {
        let items = items
        guard let current = selectedIndex(in: items) else {
            selectedID = nil
            selectedRow = 0
            return
        }
        switch direction {
        case .up:
            select(row: max(current - 1, 0), in: items)
        case .down:
            select(row: min(current + 1, items.count - 1), in: items)
        }
    }

    func select(id: ClipboardEntry.ID) {
        let items = items
        if let index = items.firstIndex(where: { $0.id == id }) {
            select(row: index, in: items)
        }
    }

    /// Clears the search and selects the first row. Called each time the window is shown.
    func prepareForPresentation() {
        query = ""
        selectFirst()
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

    private func selectFirst() {
        select(row: 0, in: items)
    }

    /// Selects the entry in `row`, or only remembers the row when the list is empty.
    private func select(row: Int, in items: [ClipboardEntry]) {
        selectedRow = row
        selectedID = items.indices.contains(row) ? items[row].id : nil
    }

    private static func clamped(_ index: Int, count: Int) -> Int? {
        guard count > 0 else {
            return nil
        }
        return min(max(index, 0), count - 1)
    }
}
