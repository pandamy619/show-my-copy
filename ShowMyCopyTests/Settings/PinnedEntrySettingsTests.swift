import Foundation
import Testing

@testable import ShowMyCopy

/// What Settings say and do about pinned entries: they count toward the size shown, the limits keep them and say
/// so, and Clear History keeps them unless the user asks to remove them too.
@MainActor
struct PinnedEntrySettingsTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private var now: Date { start + 60 }

    /// "pinned" (pinned unless `pinning` is false), "secret" (a password) and "item 0" to "item 2", newest last.
    private func makeHistory(pinning: Bool = true) -> InMemoryHistoryStore {
        let history = InMemoryHistoryStore(now: { [now] in now })
        let pinned = history.record(text: "pinned", sourceApp: nil, at: start)
        if pinning {
            history.setPinned(true, id: pinned)
        }
        history.record(text: "secret", sourceApp: nil, at: start + 1, concealed: true, expiresAt: start + 600)
        for index in 0..<3 {
            history.record(text: "item \(index)", sourceApp: nil, at: start + 2 + Double(index))
        }
        return history
    }

    private func makeUsage(_ history: InMemoryHistoryStore) -> StorageUsage {
        StorageUsage(history: .unsaved(history), memoryReader: NoMemoryUsage())
    }

    @Test func pinnedEntriesCountTowardTheSizeShown() {
        let breakdown = makeUsage(makeHistory()).breakdown
        // Text: "pinned" and three "item n", 6 bytes each; the password rounded up to a kilobyte.
        #expect(breakdown.totalCount == 5)
        #expect(breakdown.totalBytes == 24 + 1000)
        #expect(breakdown.pinnedCount == 1)
        #expect(breakdown.pinnedBytes == 6)
    }

    @Test func clearForecastKeepingPinnedLeavesThemOut() {
        let usage = makeUsage(makeHistory())
        #expect(usage.clearForecast(keepingPinned: true) == HistoryStats(count: 4, totalBytes: 18 + 1000))
        #expect(usage.clearForecast(keepingPinned: false) == HistoryStats(count: 5, totalBytes: 24 + 1000))
    }

    @Test func clearHistoryKeepingPinnedFreesWhatTheForecastSaid() {
        let history = makeHistory()
        let usage = makeUsage(history)
        let forecast = usage.clearForecast(keepingPinned: true)

        let result = usage.clearHistory(keepingPinned: true)

        #expect(result == ClearResult(removedCount: forecast.count, freedBytes: forecast.totalBytes))
        #expect(history.entries.map(\.text) == ["pinned"])
        #expect(usage.recentClear == result)
        #expect(usage.clearForecast(keepingPinned: true) == HistoryStats(count: 0, totalBytes: 0))
        // Still something to clear: the pinned entry.
        #expect(usage.hasSomethingToClear)
    }

    @Test func clearHistoryCanRemoveThePinnedEntriesToo() {
        let history = makeHistory()
        let usage = makeUsage(history)

        let result = usage.clearHistory(keepingPinned: false)

        #expect(result == ClearResult(removedCount: 5, freedBytes: 24 + 1000))
        #expect(history.entries.isEmpty)
    }

    @Test(arguments: [false, true])
    func lowerLimitsSayThatPinnedEntriesAreKept(hasPinned: Bool) throws {
        try TestDefaults.with { defaults in
            let history = makeHistory(pinning: hasPinned)
            let settings = HistorySettings(history: history, defaults: defaults, now: { [now] in now })
            let kept = hasPinned ? 1 : 0

            let fewer = settings.propose(10, for: .entries)
            #expect(fewer.keptPinnedCount == kept)
            #expect(!fewer.needsConfirmation)

            let smaller = settings.forecast(HistorySizeLimit.megabytes100, under: history.retention.withByteLimit(0))
            #expect(smaller.keptPinnedCount == kept)
            #expect(smaller.removedCount == 5 - kept)

            let shorter = settings.forecast(
                HistoryAgeLimit.hours(1), under: history.retention.withMaxAge(.seconds(1)))
            #expect(shorter.keptPinnedCount == kept)
            #expect(shorter.removedCount == 5 - kept)
        }
    }
}
