import Foundation
import Observation

@MainActor
@Observable
final class ClipboardHistory {
    nonisolated static let defaultLimit = 50
    nonisolated static let limitRange = 10...1000

    private(set) var entries: [ClipboardEntry] = []
    private(set) var limit: Int
    /// The entry whose text is on the pasteboard now, or nil when the latest pasteboard change was not recorded
    /// (a concealed, transient, empty, too large or non-text item). The newest entry is not always the current one.
    private(set) var currentEntryID: ClipboardEntry.ID?

    init(limit: Int = ClipboardHistory.defaultLimit) {
        self.limit = Self.clamped(limit)
    }

    /// Adds copied text as the newest entry and makes it current. Text that is already in the history moves to
    /// the top. Returns the ID of the entry.
    @discardableResult
    func record(text: String, sourceApp: SourceApp?, at date: Date) -> ClipboardEntry.ID {
        let entry: ClipboardEntry
        if let index = entries.firstIndex(where: { $0.text == text }) {
            var existing = entries.remove(at: index)
            existing.date = date
            existing.sourceApp = sourceApp
            entry = existing
        } else {
            entry = ClipboardEntry(id: UUID(), text: text, date: date, sourceApp: sourceApp)
        }
        entries.insert(entry, at: 0)
        currentEntryID = entry.id
        trim()
        return entry.id
    }

    /// The latest pasteboard change was not recorded, so no entry matches the pasteboard any more.
    func markCurrentSkipped() {
        currentEntryID = nil
    }

    func setLimit(_ newLimit: Int) {
        limit = Self.clamped(newLimit)
        trim()
    }

    /// How many entries a new limit would remove, for the confirmation shown before applying it.
    func entriesRemoved(byLimit newLimit: Int) -> Int {
        max(0, entries.count - Self.clamped(newLimit))
    }

    func clear() {
        entries.removeAll()
        currentEntryID = nil
    }

    private func trim() {
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
        }
        if let currentEntryID, !entries.contains(where: { $0.id == currentEntryID }) {
            self.currentEntryID = nil
        }
    }

    private static func clamped(_ value: Int) -> Int {
        min(max(value, limitRange.lowerBound), limitRange.upperBound)
    }
}
