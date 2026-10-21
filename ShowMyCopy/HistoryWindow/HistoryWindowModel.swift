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

    let history: any HistoryStore

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

    /// Concealed entries the user revealed with the eye button. Hidden again when the window closes or opens.
    private var revealedIDs: Set<ClipboardEntry.ID> = []

    init(history: any HistoryStore) {
        self.history = history
    }

    /// Entries that match the query, newest first.
    var items: [ClipboardEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return history.entries
        }
        let foldedQuery = SearchKey.fold(needle)
        return history.entries.filter { Self.entry($0, matches: foldedQuery) }
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

    /// Clears the search, hides revealed passwords and selects the first row. Called each time the window is shown.
    func prepareForPresentation() {
        query = ""
        concealAll()
        selectFirst()
        presentationCount += 1
    }

    func isRevealed(_ id: ClipboardEntry.ID) -> Bool {
        revealedIDs.contains(id)
    }

    func toggleReveal(_ id: ClipboardEntry.ID) {
        if revealedIDs.remove(id) == nil {
            revealedIDs.insert(id)
        }
    }

    /// Hides every revealed password again.
    func concealAll() {
        if !revealedIDs.isEmpty {
            revealedIDs.removeAll()
        }
    }

    /// Only the beginning of each entry is searched, so typing stays fast with long entries.
    nonisolated static let searchedCharacters = SearchKey.searchedCharacters

    /// Case- and diacritic-insensitive match against the text and the source app name, using the keys folded when
    /// the entry was made. `foldedQuery` must be folded with `SearchKey.fold(_:)`. A concealed entry matches only by
    /// its source app name, so typing part of a password does not reveal which entry holds it.
    nonisolated static func entry(_ entry: ClipboardEntry, matches foldedQuery: String) -> Bool {
        if !entry.isConcealed, SearchKey.key(entry.searchKey, contains: foldedQuery) {
            return true
        }
        return SearchKey.key(entry.sourceAppSearchKey, contains: foldedQuery)
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
