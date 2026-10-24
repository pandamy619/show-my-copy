import Foundation
import Observation

/// A part of the history in the storage breakdown. `init(of:)` switches over `ClipboardContent.Kind` without a
/// `default`, so a new kind does not compile until it is sorted into a category here.
enum StorageCategory: CaseIterable, Sendable {
    case text
    case richText
    /// Counted with their data and thumbnails in the blob store.
    case images
    /// The stored paths and names, and the thumbnails of photos and videos: the files themselves are not kept.
    case files
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
        case .richText:
            self = .richText
        case .image:
            self = .images
        case .files:
            self = .files
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

/// What the Storage settings show: how much the history takes by category and on disk, the app's memory, what
/// clearing the history frees and whether saving it works.
@MainActor
@Observable
final class StorageUsage {
    @ObservationIgnored let history: any HistoryStore
    @ObservationIgnored private let memoryReader: any MemoryUsageReading
    /// The history as a store that reports storage problems and its size on disk; nil for a history in memory.
    @ObservationIgnored private let errorReporter: (any ReportsStorageErrors)?
    @ObservationIgnored private let diskUsage: (any ReportsDiskUsage)?
    @ObservationIgnored private var cachedBreakdown: (revision: Int, breakdown: StorageBreakdown)?
    @ObservationIgnored private var cachedDiskBytes: (revision: Int, bytes: Int64?)?
    /// Changes when the size on disk should be read again, so views update `diskBytes`.
    private var diskToken = 0
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
        errorReporter = history as? any ReportsStorageErrors
        diskUsage = history as? any ReportsDiskUsage
    }

    /// Why the history is not, or not fully, saved, or nil while saving works. Reading it observes the store.
    var storageWarning: StorageWarning? {
        errorReporter?.storageError.map(StorageWarning.init)
    }

    /// How many bytes the saved history takes on disk, or nil when it is not saved in files. Read again after
    /// `history.revision` changes and after `refreshDiskBytes()`, not on every view update.
    var diskBytes: Int64? {
        _ = diskToken
        let revision = history.revision
        if let cachedDiskBytes, cachedDiskBytes.revision == revision {
            return cachedDiskBytes.bytes
        }
        let bytes = diskUsage?.storedBytes()
        cachedDiskBytes = (revision, bytes)
        return bytes
    }

    /// Reads the size on disk again, when the settings open: the database can change size without a change to
    /// the history, for example when SQLite moves its log into the store.
    func refreshDiskBytes() {
        cachedDiskBytes = nil
        diskToken &+= 1
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
