import Foundation
import Testing

@testable import ShowMyCopy

/// Returns the values it is given, one per call, then the last one again.
private final class FakeMemoryReader: MemoryUsageReading, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64?]
    private(set) var calls = 0

    init(_ values: UInt64?...) {
        self.values = values
    }

    func residentBytes() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return values.count > 1 ? values.removeFirst() : values.first.flatMap { $0 }
    }
}

@MainActor
struct StorageUsageTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeUsage(
        history: InMemoryHistoryStore,
        memory: FakeMemoryReader = FakeMemoryReader(nil)
    ) -> StorageUsage {
        StorageUsage(history: .unsaved(history), memoryReader: memory)
    }

    @Test func emptyHistoryHasNoParts() {
        let usage = makeUsage(history: InMemoryHistoryStore())
        #expect(usage.breakdown == .empty)
        #expect(usage.breakdown.parts.isEmpty)
        #expect(usage.breakdown.totalCount == 0)
        #expect(usage.breakdown.totalBytes == 0)
    }

    @Test func splitsTextAndPasswords() {
        let history = InMemoryHistoryStore()
        history.record(text: "hello", sourceApp: nil, at: start)
        history.record(text: "пароль", sourceApp: nil, at: start + 1, concealed: true, expiresAt: start + 60)
        history.record(text: "abc", sourceApp: nil, at: start + 2)

        let breakdown = makeUsage(history: history).breakdown

        // "пароль" is 6 Cyrillic letters, 2 bytes each in UTF-8, shown as a whole kilobyte (`PasswordSizeTests`).
        #expect(
            breakdown.parts == [
                StorageBreakdown.Part(category: .text, count: 2, bytes: 8),
                StorageBreakdown.Part(category: .passwords, count: 1, bytes: 1000),
            ])
        #expect(breakdown.totalCount == 3)
        #expect(breakdown.totalBytes == 1008)
    }

    @Test func leavesOutCategoriesWithoutEntries() {
        let history = InMemoryHistoryStore()
        history.record(text: "secret", sourceApp: nil, at: start, concealed: true, expiresAt: start + 60)
        let breakdown = makeUsage(history: history).breakdown
        #expect(breakdown.parts.map(\.category) == [.passwords])
    }

    @Test func partsFollowCategoryOrder() {
        let history = InMemoryHistoryStore()
        history.record(text: "secret", sourceApp: nil, at: start, concealed: true, expiresAt: start + 60)
        history.record(text: "plain", sourceApp: nil, at: start + 1)
        let breakdown = makeUsage(history: history).breakdown
        #expect(breakdown.parts.map(\.category) == [.text, .passwords])
    }

    @Test func fractionsShareTheTotalSize() {
        let history = InMemoryHistoryStore()
        history.record(text: String(repeating: "a", count: 3000), sourceApp: nil, at: start)
        history.record(
            text: String(repeating: "b", count: 10), sourceApp: nil, at: start + 1, concealed: true,
            expiresAt: start + 60)
        let breakdown = makeUsage(history: history).breakdown
        #expect(breakdown.parts.map(breakdown.fraction(of:)) == [0.75, 0.25])
        #expect(StorageBreakdown.empty.fraction(of: StorageBreakdown.Part(category: .text, count: 0, bytes: 0)) == 0)
    }

    @Test func concealingMovesAnEntryToPasswords() {
        let history = InMemoryHistoryStore()
        let id = history.record(text: "hunter2", sourceApp: nil, at: start)
        let usage = makeUsage(history: history)
        #expect(usage.breakdown.parts.map(\.category) == [.text])

        history.conceal(id: id, expiresAt: start + 60)

        #expect(usage.breakdown.parts == [StorageBreakdown.Part(category: .passwords, count: 1, bytes: 1000)])
    }

    @Test func computesOncePerRevision() {
        let history = InMemoryHistoryStore()
        history.record(text: "one", sourceApp: nil, at: start)
        let usage = makeUsage(history: history)

        _ = usage.breakdown
        _ = usage.breakdown
        _ = usage.clearForecast
        #expect(usage.breakdownComputationCount == 1)

        history.record(text: "two", sourceApp: nil, at: start + 1)
        #expect(usage.breakdown.totalCount == 2)
        _ = usage.breakdown
        #expect(usage.breakdownComputationCount == 2)

        // A call that leaves the entries as they were keeps the revision, so nothing is computed again.
        history.removeConcealed()
        _ = usage.breakdown
        #expect(usage.breakdownComputationCount == 2)
    }

    @Test func readsAppMemoryOnlyWhenAsked() {
        let memory = FakeMemoryReader(48_000_000, 50_000_000)
        let usage = makeUsage(history: InMemoryHistoryStore(), memory: memory)
        #expect(usage.appMemoryBytes == nil)
        #expect(memory.calls == 0)

        usage.refreshAppMemory()
        #expect(usage.appMemoryBytes == 48_000_000)
        usage.refreshAppMemory()
        #expect(usage.appMemoryBytes == 50_000_000)
        #expect(memory.calls == 2)
    }

    @Test func appMemoryCanBeUnavailable() {
        let usage = makeUsage(history: InMemoryHistoryStore(), memory: FakeMemoryReader(nil))
        usage.refreshAppMemory()
        #expect(usage.appMemoryBytes == nil)
    }

    // MARK: Clearing

    @Test func clearForecastMatchesWhatClearingFrees() {
        let history = InMemoryHistoryStore()
        history.record(text: "hello", sourceApp: nil, at: start)
        history.record(text: "secret", sourceApp: nil, at: start + 1, concealed: true, expiresAt: start + 60)
        let usage = makeUsage(history: history)

        let forecast = usage.clearForecast
        #expect(forecast == HistoryStats(count: 2, totalBytes: 1005))

        let result = usage.clearHistory()
        #expect(result == ClearResult(removedCount: forecast.count, freedBytes: forecast.totalBytes))
        #expect(history.entries.isEmpty)
        #expect(usage.clearForecast == HistoryStats(count: 0, totalBytes: 0))
    }

    @Test func remembersTheLastClearUntilTheHistoryChanges() {
        let history = InMemoryHistoryStore()
        history.record(text: "hello", sourceApp: nil, at: start)
        let usage = makeUsage(history: history)
        #expect(usage.recentClear == nil)

        usage.clearHistory()
        #expect(usage.recentClear == ClearResult(removedCount: 1, freedBytes: 5))

        history.record(text: "new", sourceApp: nil, at: start + 1)
        #expect(usage.recentClear == nil)
    }

    @Test func clearingAnEmptyHistoryReportsNothing() {
        let usage = makeUsage(history: InMemoryHistoryStore())
        usage.clearHistory()
        #expect(usage.recentClear == nil)
    }

    @Test func forgettingTheLastClear() {
        let history = InMemoryHistoryStore()
        history.record(text: "hello", sourceApp: nil, at: start)
        let usage = makeUsage(history: history)
        usage.clearHistory()

        usage.forgetRecentClear()

        #expect(usage.recentClear == nil)
    }
}

struct ByteCountTests {
    private let english = Locale(identifier: "en_US")
    private let russian = Locale(identifier: "ru_RU")

    @Test(arguments: [
        (1_234_567, "1.2 MB"),
        (48_000_000, "48 MB"),
        (100_000_000, "100 MB"),
        (500_000_000, "500 MB"),
        (1_000_000_000, "1 GB"),
    ])
    func formatsFileSizesInDecimalUnits(bytes: Int, expected: String) {
        #expect(ByteCount.fileSize(bytes, locale: english) == expected)
    }

    @Test func formatsFileSizesForTheLocale() {
        #expect(ByteCount.fileSize(1_234_567, locale: russian) == "1,2 МБ")
    }

    @Test func formatsMemoryInBinaryUnits() {
        // 48 MiB, as Activity Monitor counts memory.
        #expect(ByteCount.memorySize(50_331_648, locale: english) == "48 MB")
    }

    @Test func formatsHugeMemoryValuesWithoutOverflow() {
        #expect(!ByteCount.memorySize(.max, locale: english).isEmpty)
    }

    @Test func treatsNegativeSizesAsZero() {
        #expect(ByteCount.fileSize(-5, locale: english) == ByteCount.fileSize(0, locale: english))
    }
}
