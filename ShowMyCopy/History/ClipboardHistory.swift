import Foundation
import Observation

@MainActor
@Observable
final class ClipboardHistory {
    nonisolated static let defaultLimit = 50
    nonisolated static let limitRange = 10...1000

    private(set) var entries: [ClipboardEntry] = []
    private(set) var limit: Int

    init(limit: Int = ClipboardHistory.defaultLimit) {
        self.limit = Self.clamped(limit)
    }

    /// Adds copied text as the newest entry. Text that is already in the history moves to the top.
    func record(text: String, sourceApp: SourceApp?, at date: Date) {
        if let index = entries.firstIndex(where: { $0.text == text }) {
            var entry = entries.remove(at: index)
            entry.date = date
            entry.sourceApp = sourceApp
            entries.insert(entry, at: 0)
            return
        }
        entries.insert(ClipboardEntry(id: UUID(), text: text, date: date, sourceApp: sourceApp), at: 0)
        trim()
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
    }

    private func trim() {
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
        }
    }

    private static func clamped(_ value: Int) -> Int {
        min(max(value, limitRange.lowerBound), limitRange.upperBound)
    }
}
