import Foundation
import Observation

/// State of the history window: the search query, the listed sections, the selected entry and its preview.
@MainActor
@Observable
final class HistoryWindowModel {
    let history: any HistoryStore
    private let deleter: any EntryDeleting
    /// The large preview of the selected entry.
    let preview: EntryPreviewModel
    /// Thumbnails for image rows, loaded as rows appear.
    let thumbnails: ThumbnailProvider
    /// The row swiped open to show the buttons of its actions (`HistoryWindowModel+Swipe.swift`).
    let swipe = RowSwipe()
    /// Where a dragged image is read from when the app it is dropped on asks for it (`EntryDrag`). Without it images
    /// cannot be dragged.
    let imageBlobs: (any BlobStore)?
    private let fileAvailability: any FileAvailabilityChecking
    /// Settings → General → Paste after choosing an entry, read on every Return.
    private let pastesAfterChoosing: @MainActor () -> Bool
    /// The accounts whose codes the window lists (`codeRows`). Nil: no codes section.
    let codes: CodeAccountStore?

    /// Why the last paste only copied, told once in the window opening now (`EntryPasting.takeFallbackHint()`). The
    /// view shows it above the list until the user dismisses it; opening or closing the window clears it.
    var pasteHint: PasteFallback?

    /// Whether the Codes section is shown (`codeRows`), under the search bar. Off each time the window opens: codes
    /// appear only after the user asks for them with the button next to the gear, so they are never on screen
    /// unasked.
    var showsCodes = false

    /// Whether the last pin or Undo here unpinned the oldest pinned entry to keep `RetentionPolicy.maximumPinned`
    /// (`noticingPinLimit`). The view shows one line above the list until the user dismisses it.
    var showsPinLimitNotice = false {
        didSet {
            if showsPinLimitNotice {
                pinLimitNoticeCount += 1
            }
        }
    }

    /// How often the notice was shown, also again while it is on screen, so VoiceOver announces every one.
    private(set) var pinLimitNoticeCount = 0

    var query = "" {
        didSet {
            if query != oldValue {
                // Typing closes a swiped row.
                swipe.close()
                selectFirst()
                // The list changes under the preview: close it rather than show an entry that may be filtered out.
                preview.close()
            }
        }
    }

    /// The selected row, entry or code. It is kept by ID, so the selection stays on the same row when a copy
    /// arrives or an entry moves to the top or to another section while the window is open. Read `selectedRowID`,
    /// `selectedEntry` or `selectedCode`, which find it among the rows listed now.
    private var selectedID: UUID?

    /// The row that was selected when it was selected (`rows`). Used when the selected row is gone, so the
    /// selection stays near where it was instead of jumping to the top.
    private var selectedRow = 0

    /// Changes every time the window is shown, so the view can move focus to the search field.
    private(set) var presentationCount = 0

    /// Concealed entries the user revealed with the eye button. Hidden again when the window closes or opens.
    private var revealedIDs: Set<ClipboardEntry.ID> = []

    init(
        history: any HistoryStore,
        deleter: any EntryDeleting,
        previews: PreviewServices = PreviewServices(),
        codes: CodeAccountStore? = nil,
        pastesAfterChoosing: @escaping @MainActor () -> Bool
    ) {
        self.history = history
        self.deleter = deleter
        self.codes = codes
        preview = EntryPreviewModel(services: previews)
        thumbnails = ThumbnailProvider(blobs: previews.blobs, decoder: previews.images)
        imageBlobs = previews.blobs
        fileAvailability = previews.fileAvailability
        self.pastesAfterChoosing = pastesAfterChoosing
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

    /// The listed entries in the order the window shows them.
    var items: [ClipboardEntry] {
        sections.rows
    }

    /// The entry whose text is on the clipboard now. Nil after a copy that was not recorded, such as a password
    /// or an image: then the newest entry is no longer on the clipboard and the window shows no current entry.
    var currentEntryID: ClipboardEntry.ID? {
        history.currentEntryID
    }

    /// The selected row within `rows`, the rows listed now: the row with the selected ID, or the row nearest to
    /// where the selection was when that row is gone. Nil with nothing listed.
    func selectedRowIndex(in rows: [HistoryRowItem]) -> Int? {
        if let selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }) {
            return index
        }
        return Self.clamped(selectedRow, count: rows.count)
    }

    /// The ID of the selected row, entry or code, for the view to highlight it.
    var selectedRowID: UUID? {
        let rows = rows
        return selectedRowIndex(in: rows).map { rows[$0].id }
    }

    /// The selected row, entry or code.
    var selectedItem: HistoryRowItem? {
        let rows = rows
        return selectedRowIndex(in: rows).map { rows[$0] }
    }

    /// The selected entry within the listed entries, or nil when a code is selected or nothing is listed.
    var selectedIndex: Int? {
        selectedIndex(in: items)
    }

    /// The selected entry's index within an already filtered list, so callers don't filter the history twice.
    func selectedIndex(in items: [ClipboardEntry]) -> Int? {
        guard let selected = selectedEntry else {
            return nil
        }
        return items.firstIndex { $0.id == selected.id }
    }

    /// The selected entry; nil when a code is selected.
    var selectedEntry: ClipboardEntry? {
        selectedItem?.entry
    }

    /// The selected account; nil when an entry is selected.
    var selectedCode: CodeAccount? {
        selectedItem?.code
    }

    func moveSelection(_ direction: Direction) {
        let rows = rows
        guard let current = selectedRowIndex(in: rows) else {
            selectedID = nil
            selectedRow = 0
            return
        }
        switch direction {
        case .up:
            select(row: max(current - 1, 0), in: rows)
        case .down:
            select(row: min(current + 1, rows.count - 1), in: rows)
        }
    }

    /// Clears the search, hides revealed passwords and the paste hint, closes the preview and selects the first row.
    /// Called each time the window is shown.
    func prepareForPresentation() {
        // Undo works only in the window the entry was deleted in.
        deleter.finishDeleting()
        swipe.close()
        query = ""
        concealAll()
        preview.close()
        selectFirst()
        pasteHint = nil
        showsPinLimitNotice = false
        showsCodes = false
        presentationCount += 1
    }

    /// Whether ⌘Z has an entry to bring back.
    var canUndoDelete: Bool {
        deleter.canUndoDelete
    }

    /// Shows the Codes section, or hides it when it is shown, for the button next to the gear and ⌘K. Showing it
    /// selects the first code, so Return right after copies it; hiding it selects the first row again.
    func toggleCodes() {
        swipe.close()
        showsCodes.toggle()
        selectFirst()
    }

    /// Whether choosing an entry pastes it: as Settings say, or the other way round with ⌥ (`isAlternate`). For
    /// Return and ⌥Return, and for a click or ⌥-click on a row.
    func choosingPastes(isAlternate: Bool) -> Bool {
        pastesAfterChoosing() != isAlternate
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
        select(id: entry.id)
        preview.open(entry)
    }

    /// Selects the row of the account, for a click on its row.
    func select(_ account: CodeAccount) {
        select(id: account.id)
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

    private func selectFirst() {
        select(row: 0, in: rows)
    }

    /// Selects the listed row with `id`, when there is one.
    private func select(id: UUID) {
        let rows = rows
        if let row = rows.firstIndex(where: { $0.id == id }) {
            select(row: row, in: rows)
        }
    }

    /// Selects the row at `row`, or only remembers the row when the list is empty.
    private func select(row: Int, in rows: [HistoryRowItem]) {
        selectedRow = row
        let id = rows.indices.contains(row) ? rows[row].id : nil
        if id != selectedID {
            // A new selection closes a swiped row.
            swipe.close()
        }
        selectedID = id
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
    /// Deletes `entry`, for ⌘⌫, the row's "Delete" action, VoiceOver and swipe to delete. The window stays open. When
    /// the entry was selected, the entry after it is selected, or the one before it when it was the last.
    func delete(_ entry: ClipboardEntry) {
        swipe.close()
        let rows = rows
        let row = rows.firstIndex { $0.id == entry.id }
        let wasSelected = row != nil && row == selectedRowIndex(in: rows)
        let neighbours = row.map { row in
            [row + 1, row - 1].filter(rows.indices.contains).map { rows[$0].id }
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
        let remaining = self.rows
        let neighbourRow = neighbours.lazy.compactMap { id in remaining.firstIndex { $0.id == id } }.first
        select(row: neighbourRow ?? max(min(row, remaining.count - 1), 0), in: remaining)
    }

    /// Brings back the entry deleted last and selects it, for ⌘Z.
    func undoDelete() {
        // A pinned entry brought back can make one too many pinned (`HistoryStore.restore(_:)`).
        guard let id = noticingPinLimit(acting: nil, { deleter.undoDelete() }) else {
            return
        }
        select(id: id)
    }

    /// The window closed: the deleted entry can no longer come back, and its files are deleted.
    func finishDeleting() {
        deleter.finishDeleting()
    }
}
