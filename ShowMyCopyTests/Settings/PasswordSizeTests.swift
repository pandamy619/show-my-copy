import Foundation
import Testing

@testable import ShowMyCopy

/// Settings never show how long a saved password is: the passwords' total size is shown rounded up to whole
/// kilobytes, and every figure that includes it (the history size, the bar, what clearing or a lower limit frees) adds
/// the rounded size, so subtracting the other parts does not give it away either.
@MainActor
struct PasswordSizeTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeUsage(history: InMemoryHistoryStore) -> StorageUsage {
        StorageUsage(history: .unsaved(history), memoryReader: NoMemoryUsage())
    }

    private func recordPassword(_ text: String, in history: InMemoryHistoryStore, at offset: TimeInterval = 0) {
        history.record(
            text: text, sourceApp: nil, at: start + offset, concealed: true, expiresAt: start + offset + 600)
    }

    @Test func onePasswordShowsAsAWholeKilobyte() {
        let history = InMemoryHistoryStore()
        history.record(text: "hello", sourceApp: nil, at: start)
        recordPassword("hunter2", in: history, at: 1)

        let breakdown = makeUsage(history: history).breakdown

        #expect(
            breakdown.parts == [
                StorageBreakdown.Part(category: .text, count: 1, bytes: 5),
                StorageBreakdown.Part(category: .passwords, count: 1, bytes: 1000),
            ])
        #expect(breakdown.totalBytes == 1005)
        #expect(breakdown.fraction(of: breakdown.parts[1]) == 1000.0 / 1005.0)
    }

    @Test(arguments: [1, 7, 64, 999, 1000])
    func passwordsOfAnyLengthUpToAKilobyteLookTheSame(length: Int) {
        let history = InMemoryHistoryStore()
        history.record(text: "hello", sourceApp: nil, at: start)
        recordPassword(String(repeating: "p", count: length), in: history, at: 1)

        let breakdown = makeUsage(history: history).breakdown

        #expect(breakdown.parts.last == StorageBreakdown.Part(category: .passwords, count: 1, bytes: 1000))
        #expect(breakdown.totalBytes == 1005)
        let forecast = makeUsage(history: history).clearForecast(keepingPinned: false)
        #expect(forecast == HistoryStats(count: 2, totalBytes: 1005))
    }

    /// The passwords' total is rounded, not each password, so many short passwords do not add up to kilobytes.
    @Test func theTotalOfAllPasswordsIsRoundedUp() {
        let history = InMemoryHistoryStore()
        recordPassword(String(repeating: "a", count: 600), in: history)
        recordPassword(String(repeating: "b", count: 400), in: history, at: 1)
        #expect(makeUsage(history: history).breakdown.parts.map(\.bytes) == [1000])

        recordPassword("c", in: history, at: 2)
        #expect(makeUsage(history: history).breakdown.parts.map(\.bytes) == [2000])
    }

    @Test func whatClearingFreedShowsThePasswordsRounded() {
        let history = InMemoryHistoryStore()
        history.record(text: "hello", sourceApp: nil, at: start)
        recordPassword("hunter2", in: history, at: 1)
        let usage = makeUsage(history: history)

        let result = usage.clearHistory(keepingPinned: false)

        #expect(result == ClearResult(removedCount: 2, freedBytes: 1005))
        #expect(usage.recentClear == ClearResult(removedCount: 2, freedBytes: 1005))
        #expect(history.entries.isEmpty)
    }

    @Test func whatALowerLimitFreesShowsThePasswordsRounded() throws {
        try TestDefaults.with { defaults in
            let history = InMemoryHistoryStore(
                retention: RetentionPolicy(entryLimit: RetentionPolicy.entryLimitRange.upperBound),
                now: { [start] in start + 60 })
            let settings = HistorySettings(history: history, defaults: defaults, now: { [start] in start + 60 })
            recordPassword("hunter2", in: history)
            for index in 1...10 {
                history.record(text: "item\(index)", sourceApp: nil, at: start + Double(index))
            }

            // The oldest entry, the password, is the only one the limit of 10 removes.
            #expect(
                settings.propose(10, for: .entries)
                    == LimitChange(limit: 10, removedCount: 1, freedBytes: 1000, keptPinnedCount: 0))
        }
    }

    @Test func withoutPasswordsSizesAreExact() {
        let history = InMemoryHistoryStore()
        history.record(text: "hello", sourceApp: nil, at: start)
        history.record(text: "abc", sourceApp: nil, at: start + 1)
        let breakdown = makeUsage(history: history).breakdown
        #expect(breakdown.totalBytes == 8)
        #expect(breakdown.totalBytes == history.stats().totalBytes)
    }
}
