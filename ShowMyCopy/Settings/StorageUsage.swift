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
    /// Where the history is saved: problems saving it, its size on disk and a damaged copy.
    @ObservationIgnored private let storage: any HistoryStorage
    @ObservationIgnored private let memoryReader: any MemoryUsageReading
    @ObservationIgnored private var cachedBreakdown: (revision: Int, breakdown: StorageBreakdown)?
    /// Whether the size on disk is being measured. One measurement runs at a time.
    @ObservationIgnored private var isMeasuringDisk = false
    /// A measurement asked for while one ran, to run after it; true when it counts the images again.
    @ObservationIgnored private var pendingMeasurement: Bool?
    /// What the last `clearHistory()` removed and the history's revision right after it.
    @ObservationIgnored private var lastClear: (result: ClearResult, revision: Int)?
    /// How often the breakdown was computed, so tests can check the cache.
    @ObservationIgnored private(set) var breakdownComputationCount = 0

    /// The app's memory footprint from the last `refreshAppMemory()`, or nil before it or when it is not reported.
    private(set) var appMemoryBytes: UInt64?
    /// Changes when the history is cleared or the clear is forgotten, so views update `recentClear`.
    private var clearToken = 0

    init(history: AppHistory, memoryReader: any MemoryUsageReading) {
        self.history = history.store
        self.storage = history.storage
        self.memoryReader = memoryReader
    }

    /// The size of a copy of a history that could not be opened, or nil when there is none. Reading it observes
    /// the store.
    var damagedHistoryBytes: Int64? {
        storage.damagedHistoryBytes
    }

    /// Whether Clear History would remove anything: entries, or a damaged copy of a history.
    var hasSomethingToClear: Bool {
        !history.entries.isEmpty || damagedHistoryBytes != nil
    }

    /// Why the history is not, or not fully, saved, or nil while saving works. Reading it observes the store.
    var storageWarning: StorageWarning? {
        storage.storageError.map(StorageWarning.init)
    }

    /// How many bytes the saved history takes on disk, as last measured by `refreshDiskBytes`, or nil before that
    /// and when it is not saved in files.
    private(set) var diskBytes: Int64?

    /// Measures the size on disk again, off the main actor, and updates `diskBytes`. Call it when the settings open
    /// (`recountingImages`: the saved images are counted again from the disk, in the background) and after the
    /// history changes while they are shown (the images' running total is used, so nothing lists their folder). The
    /// database can also change size without a change to the history, for example when SQLite moves its log into
    /// the store.
    ///
    /// One measurement runs at a time: one asked for meanwhile runs right after it, and returns at once.
    func refreshDiskBytes(recountingImages: Bool = false) async {
        guard !isMeasuringDisk else {
            pendingMeasurement = pendingMeasurement == true || recountingImages
            return
        }
        isMeasuringDisk = true
        var recounts = recountingImages
        while true {
            let bytes = await storage.storedBytes(recountingBlobs: recounts)
            if bytes != diskBytes {
                diskBytes = bytes
            }
            guard let next = pendingMeasurement else {
                break
            }
            pendingMeasurement = nil
            recounts = next
        }
        isMeasuringDisk = false
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
