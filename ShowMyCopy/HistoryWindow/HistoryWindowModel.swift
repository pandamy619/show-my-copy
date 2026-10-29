import Foundation
import Observation

/// State of the history window: the search query, the listed sections, the selected entry and its preview.
@MainActor
@Observable
final class HistoryWindowModel {
    enum Direction: Sendable {
        case up
        case down
    }

    /// The keys the history window handles, whether the search field or the list has focus.
    enum Key: Sendable {
        case up
        case down
        case left
        case right
        case `return`
        case escape
        /// ⌘⌫: deletes the selected entry. Delete without ⌘ edits the search text.
        case delete
        /// ⌘Z: brings back the entry deleted last, while there is one. Otherwise it undoes typing in the search field.
        case undo
        /// ⌘P: pins or unpins the selected entry. Always handled, so it never reaches the search field or Print.
        case pin
    }

    /// What the view does after the model handled a key.
    enum KeyResult: Equatable {
        /// The model handled it; nothing else to do.
        case handled
        /// Not for the history window: the search field gets it, for example to move the caret.
        case ignored
        /// Copy this entry back to the clipboard.
        case choose(ClipboardEntry)
        /// Close the history window.
        case close
    }

    let history: any HistoryStore
    private let deleter: any EntryDeleting
    /// The large preview of the selected entry.
    let preview: EntryPreviewModel
    /// Thumbnails for image rows, loaded as rows appear.
    let thumbnails: ThumbnailProvider
    private let fileAvailability: any FileAvailabilityChecking

    var query = "" {
        didSet {
            if query != oldValue {
                selectFirst()
                // The list changes under the preview: close it rather than show an entry that may be filtered out.
                preview.close()
            }
        }
    }

    /// The selected entry. It is kept by ID, so the selection stays on the same entry when a copy arrives or an
    /// entry moves to the top or to another section while the window is open. Read `selectedIndex`, which finds its
    /// row.
    private var selectedID: ClipboardEntry.ID?

    /// The row of the selected entry when it was selected. Used when there is no selected entry or it is gone,
    /// so the selection stays near where it was instead of jumping to the top.
    private var selectedRow = 0

    /// Changes every time the window is shown, so the view can move focus to the search field.
    private(set) var presentationCount = 0

    /// Concealed entries the user revealed with the eye button. Hidden again when the window closes or opens.
    private var revealedIDs: Set<ClipboardEntry.ID> = []

    init(history: any HistoryStore, deleter: any EntryDeleting, previews: PreviewServices = PreviewServices()) {
        self.history = history
        self.deleter = deleter
        preview = EntryPreviewModel(services: previews)
        thumbnails = ThumbnailProvider(blobs: previews.blobs, decoder: previews.images)
        fileAvailability = previews.fileAvailability
    }

    /// What the cached sections were computed from. While it stays the same, so do the entries listed.
    private struct ListInput: Equatable {
        let query: String
        let revision: Int
        let currentEntryID: ClipboardEntry.ID?
        // Cheap extra checks, in case a store misses a revision.
        let count: Int
        let firstID: ClipboardEntry.ID?
        let lastID: ClipboardEntry.ID?
    }

    /// The positions of the listed entries, not copies of the entries, so an entry the history removes (such as an
    /// expired password) is not kept alive here.
    @ObservationIgnored private var cachedList: (input: ListInput, positions: HistorySections.Positions)?

    /// How often the history was searched. Tests read it to check that the search result is reused.
    @ObservationIgnored private(set) var filterCount = 0

    /// The entries that match the query, by section (`HistorySections`): the clipboard row, the pinned entries and
    /// the rest. Search filters every section.
    ///
    /// The view reads this several times per update, and once per keystroke the query changes. The result is
    /// reused until the query, the history's entries or the current entry change. Matching uses the search keys made
    /// when the entries were recorded, so only the query is folded.
    var sections: HistorySections {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = history.entries
        let input = ListInput(
            query: needle,
            revision: history.revision,
            currentEntryID: history.currentEntryID,
            count: entries.count,
            firstID: entries.first?.id,
            lastID: entries.last?.id
        )
        if let cachedList, cachedList.input == input {
            return cachedList.positions.sections(in: entries)
        }
        var listed = Array(entries.indices)
        if !needle.isEmpty {
            filterCount += 1
            let foldedQuery = SearchKey.fold(needle)
            listed = listed.filter { Self.entry(entries[$0], matches: foldedQuery) }
        }
        let positions = HistorySections.Positions(of: entries, listed: listed, currentEntryID: input.currentEntryID)
        cachedList = (input, positions)
        return positions.sections(in: entries)
    }

    /// The listed entries in the order the window shows them: the arrow keys move through these.
    var items: [ClipboardEntry] {
        sections.rows
    }

    /// Whether the window lists any entries. False for an empty history and for a search with no matches: then
    /// the window shrinks to the search bar and a one-line message. Observable, like `items`.
    var showsEntries: Bool {
        !items.isEmpty
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

    /// Clears the search, hides revealed passwords, closes the preview and selects the first row. Called each time
    /// the window is shown.
    func prepareForPresentation() {
        // Undo works only in the window the entry was deleted in.
        deleter.finishDeleting()
        query = ""
        concealAll()
        preview.close()
        selectFirst()
        presentationCount += 1
    }

    /// Handles a key press. `isCaretAtEnd` is false while the caret of the search field is not after its last
    /// character: then Left and Right Arrow move the caret instead.
    ///
    /// Up and Down Arrow move the selection, and the open preview follows it. Right Arrow opens the preview, like
    /// opening a folder in a column view; Left Arrow and Esc close it. Esc with no preview closes the window, and
    /// Return copies the selected entry back. ⌘⌫ deletes the selected entry and ⌘Z brings it back; with nothing to
    /// delete or bring back they are left to the search field. ⌘P pins or unpins the selected entry.
    func handleKey(_ key: Key, isCaretAtEnd: Bool) -> KeyResult {
        switch key {
        case .delete, .undo, .pin:
            return handleCommandKey(key)
        case .up, .down:
            moveSelection(key == .up ? .up : .down)
            if preview.isOpen {
                showPreviewOfSelection()
            }
            return .handled
        case .right:
            guard !preview.isOpen, isCaretAtEnd, let entry = selectedEntry, EntryPreviewModel.canPreview(entry) else {
                return .ignored
            }
            preview.open(entry)
            return .handled
        case .left:
            guard preview.isOpen else {
                return .ignored
            }
            preview.close()
            return .handled
        case .escape:
            guard preview.isOpen else {
                return .close
            }
            preview.close()
            return .handled
        case .return:
            return selectedEntry.map { .choose($0) } ?? .handled
        }
    }

    /// Opens the preview of the selected entry, or closes it when there is none or it cannot be previewed. For the
    /// row's "Show Preview" action and the arrow keys.
    func showPreviewOfSelection() {
        if let entry = selectedEntry {
            preview.open(entry)
        } else {
            preview.close()
        }
    }

    /// Selects `entry` and shows its preview, for the row's "Show Preview" action.
    func showPreview(of entry: ClipboardEntry) {
        let items = items
        if let row = items.firstIndex(where: { $0.id == entry.id }) {
            select(row: row, in: items)
        }
        preview.open(entry)
    }

    /// The preview to show: the open preview's entry while it is still listed. An entry removed from the history
    /// or filtered out while its preview is open is not shown.
    var previewedEntry: ClipboardEntry? {
        guard let id = preview.entryID else {
            return nil
        }
        return items.first { $0.id == id }
    }

    /// The open preview's entry changed in the history: its image was saved, or its files got thumbnails and sizes,
    /// after the preview opened. The view calls this when it sees the change, so the preview shows them at once.
    func previewedEntryChanged() {
        if let entry = previewedEntry {
            preview.open(entry)
        }
    }

    /// Whether the copied files of a row may be unavailable, checked off the main actor when the row appears.
    func availability(of files: [FileReference]) async -> FileAvailability {
        FileAvailabilityProbe.summary(await FileAvailabilityProbe.check(files, with: fileAvailability))
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

// MARK: - Deleting

extension HistoryWindowModel {
    /// ⌘⌫ and ⌘Z, left to the search field when there is nothing to delete or bring back, and ⌘P, always handled.
    fileprivate func handleCommandKey(_ key: Key) -> KeyResult {
        if key == .pin {
            if let entry = selectedEntry {
                togglePin(entry)
            }
            return .handled
        }
        if key == .undo {
            guard deleter.canUndoDelete else {
                return .ignored
            }
            undoDelete()
            return .handled
        }
        guard let entry = selectedEntry else {
            return .ignored
        }
        delete(entry)
        return .handled
    }

    /// Deletes `entry`, for ⌘⌫, the row's "Delete" action and VoiceOver. The window stays open. When the entry was
    /// selected, the entry after it is selected, or the one before it when it was the last.
    func delete(_ entry: ClipboardEntry) {
        let items = items
        let row = items.firstIndex { $0.id == entry.id }
        let wasSelected = row != nil && row == selectedIndex(in: items)
        let neighbours = row.map { row in
            [row + 1, row - 1].filter(items.indices.contains).map { items[$0].id }
        }
        deleter.delete(entry.id)
        revealedIDs.remove(entry.id)
        if preview.entryID == entry.id {
            preview.close()
        }
        guard wasSelected, let row, let neighbours else {
            return
        }
        // The neighbours by ID: a copy recorded meanwhile may have moved the rows.
        let remaining = self.items
        let neighbourRow = neighbours.lazy.compactMap { id in remaining.firstIndex { $0.id == id } }.first
        select(row: neighbourRow ?? max(min(row, remaining.count - 1), 0), in: remaining)
    }

    /// Brings back the entry deleted last and selects it, for ⌘Z.
    func undoDelete() {
        guard let id = deleter.undoDelete() else {
            return
        }
        let items = items
        if let row = items.firstIndex(where: { $0.id == id }) {
            select(row: row, in: items)
        }
    }

    /// The window closed: the deleted entry can no longer come back, and its files are deleted.
    func finishDeleting() {
        deleter.finishDeleting()
    }
}
