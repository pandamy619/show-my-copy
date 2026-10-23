import Foundation
import Observation

/// A part of the history in the storage breakdown. Images and files get their own cases when the history keeps
/// them; `init(of:)` switches over `ClipboardContent.Kind` without a `default`, so a new kind does not compile until
/// it is sorted into a category here.
enum StorageCategory: CaseIterable, Sendable {
    case text
    case passwords

    init(of entry: ClipboardEntry) {
        // A password counts as a password whatever its kind, so the breakdown never shows it as text.
        if entry.isConcealed {
            self = .passwords
            return
        }
        switch entry.kind {
        case .text:
            self = .text
        }
    }
}

/// How the history's size splits into categories.
struct StorageBreakdown: Equatable, Sendable {
    struct Part: Equatable, Sendable, Identifiable {
        let category: StorageCategory
        let count: Int
        /// The total `byteSize` of the part's entries.
        let bytes: Int

        var id: StorageCategory { category }
    }

    static let empty = StorageBreakdown(entries: [])

    /// The categories that have entries, in `StorageCategory.allCases` order.
    let parts: [Part]
    let totalCount: Int
    let totalBytes: Int

    init(entries: [ClipboardEntry]) {
        var counts: [StorageCategory: Int] = [:]
        var bytes: [StorageCategory: Int] = [:]
        for entry in entries {
            let category = StorageCategory(of: entry)
            counts[category, default: 0] += 1
            bytes[category, default: 0] += entry.byteSize
        }
        parts = StorageCategory.allCases.compactMap { category in
            counts[category].map { Part(category: category, count: $0, bytes: bytes[category, default: 0]) }
        }
        totalCount = entries.count
        totalBytes = parts.reduce(0) { $0 + $1.bytes }
    }

    /// The part's share of the total size, from 0 to 1. Zero when the history holds no bytes.
    func fraction(of part: Part) -> Double {
        totalBytes > 0 ? Double(part.bytes) / Double(totalBytes) : 0
    }
}

/// What the Storage settings show: how much the history takes by category, the app's memory and what clearing
/// the history frees.
@MainActor
@Observable
final class StorageUsage {
    @ObservationIgnored let history: any HistoryStore
    @ObservationIgnored private let memoryReader: any MemoryUsageReading
    @ObservationIgnored private var cachedBreakdown: (revision: Int, breakdown: StorageBreakdown)?
    /// What the last `clearHistory()` removed and the history's revision right after it.
    @ObservationIgnored private var lastClear: (result: ClearResult, revision: Int)?
    /// How often the breakdown was computed, so tests can check the cache.
    @ObservationIgnored private(set) var breakdownComputationCount = 0

    /// The app's memory footprint from the last `refreshAppMemory()`, or nil before it or when it is not reported.
    private(set) var appMemoryBytes: UInt64?
    /// Changes when the history is cleared or the clear is forgotten, so views update `recentClear`.
    private var clearToken = 0

    init(history: any HistoryStore, memoryReader: any MemoryUsageReading) {
        self.history = history
        self.memoryReader = memoryReader
    }

    /// The breakdown of the current entries. Computed again only after `history.revision` changes, so a view can
    /// read it on every update without walking the entries. Reading it observes the history.
    var breakdown: StorageBreakdown {
        let revision = history.revision
        if let cachedBreakdown, cachedBreakdown.revision == revision {
            return cachedBreakdown.breakdown
        }
        let breakdown = StorageBreakdown(entries: history.entries)
        cachedBreakdown = (revision, breakdown)
        breakdownComputationCount += 1
        return breakdown
    }

    /// What clearing the history would remove now.
    var clearForecast: HistoryStats {
        let breakdown = breakdown
        return HistoryStats(count: breakdown.totalCount, totalBytes: breakdown.totalBytes)
    }

    /// What the last clear removed, until the history changes again. Nil when nothing was removed.
    var recentClear: ClearResult? {
        _ = clearToken
        guard let lastClear, lastClear.revision == history.revision else {
            return nil
        }
        return lastClear.result
    }

    /// Reads the app's memory again. Call it while the numbers are on screen.
    func refreshAppMemory() {
        let bytes = memoryReader.residentBytes()
        if bytes != appMemoryBytes {
            appMemoryBytes = bytes
        }
    }

    /// Removes every entry and remembers what was freed, for a calm note in place of the button.
    @discardableResult
    func clearHistory() -> ClearResult {
        let result = history.clear()
        lastClear = result.removedCount > 0 ? (result, history.revision) : nil
        clearToken &+= 1
        return result
    }

    /// Hides the note about the last clear, when the settings close.
    func forgetRecentClear() {
        guard lastClear != nil else {
            return
        }
        lastClear = nil
        clearToken &+= 1
    }
}
