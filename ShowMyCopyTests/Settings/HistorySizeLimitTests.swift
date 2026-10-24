import Foundation
import Testing

@testable import ShowMyCopy

@MainActor
struct HistorySizeLimitTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// Runs `body` with an empty UserDefaults suite that is removed afterwards.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "ShowMyCopyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    /// Settings as the app sets them up when it starts: the saved limits are applied to the history.
    private func makeSettings(history: ClipboardHistory, defaults: UserDefaults) -> HistorySettings {
        let settings = HistorySettings(history: history, defaults: defaults)
        settings.applyStoredLimit()
        return settings
    }

    /// Entries "item 0" (oldest) to "item 9", 6 bytes each.
    private func makeHistory() -> ClipboardHistory {
        let history = ClipboardHistory(limit: ClipboardHistory.limitRange.upperBound)
        for index in 0..<10 {
            history.record(text: "item \(index)", sourceApp: nil, at: start + Double(index))
        }
        return history
    }

    @Test func optionsAreInIncreasingOrderWithNoLimitFirst() {
        #expect(HistorySizeLimit.allCases == [.noLimit, .megabytes100, .megabytes500, .gigabyte1])
        #expect(HistorySizeLimit.allCases.map(\.byteLimit) == [nil, 100_000_000, 500_000_000, 1_000_000_000])
    }

    @Test func oneGigabyteByDefault() throws {
        try withDefaults { defaults in
            let history = ClipboardHistory()
            let settings = makeSettings(history: history, defaults: defaults)
            #expect(HistorySettings.storedSizeLimit(in: defaults) == .gigabyte1)
            #expect(settings.sizeLimit == .gigabyte1)
            #expect(history.retention.byteLimit == 1_000_000_000)
        }
    }

    @Test func appliesSavedSizeLimitTogetherWithTheEntryLimit() throws {
        try withDefaults { defaults in
            defaults.set(120, forKey: SettingsKey.historyLimit)
            defaults.set(500_000_000, forKey: SettingsKey.historyByteLimit)
            let history = ClipboardHistory()

            let settings = makeSettings(history: history, defaults: defaults)

            #expect(history.retention == RetentionPolicy(entryLimit: 120, byteLimit: 500_000_000))
            #expect(settings.sizeLimit == .megabytes500)
            #expect(settings.limit == 120)
        }
    }

    @Test func creatingSettingsLeavesTheSizeLimitAlone() throws {
        try withDefaults { defaults in
            defaults.set(100_000_000, forKey: SettingsKey.historyByteLimit)
            let history = ClipboardHistory()
            _ = HistorySettings(history: history, defaults: defaults)
            #expect(history.retention.byteLimit == nil)
        }
    }

    @Test func appliedSizeLimitPersistsAcrossInstances() throws {
        try withDefaults { defaults in
            let first = makeSettings(history: ClipboardHistory(), defaults: defaults)
            first.applySizeLimit(.gigabyte1)
            #expect(defaults.object(forKey: SettingsKey.historyByteLimit) as? Int == 1_000_000_000)

            let history = ClipboardHistory()
            let second = makeSettings(history: history, defaults: defaults)
            #expect(second.sizeLimit == .gigabyte1)
            #expect(history.retention.byteLimit == 1_000_000_000)
        }
    }

    @Test func choosingNoLimitIsSavedExplicitly() throws {
        try withDefaults { defaults in
            let settings = makeSettings(history: ClipboardHistory(), defaults: defaults)
            settings.applySizeLimit(.megabytes100)
            settings.applySizeLimit(.noLimit)

            // Saved, so a later change of the default does not override the user's choice.
            #expect(defaults.object(forKey: SettingsKey.historyByteLimit) as? Int == 0)
            #expect(HistorySettings.storedSizeLimit(in: defaults) == .noLimit)
            #expect(settings.history.retention.byteLimit == nil)
        }
    }

    @Test func ignoresSavedSizeOfWrongTypeOrSign() throws {
        try withDefaults { defaults in
            for value: Any in ["lots", ["a": 1], -1, Int.min] {
                defaults.set(value, forKey: SettingsKey.historyByteLimit)
                #expect(HistorySettings.storedSizeLimit(in: defaults) == .default)
            }
        }
    }

    @Test(arguments: [
        (1, HistorySizeLimit.megabytes100),
        (100_000_000, .megabytes100),
        (100_000_001, .megabytes500),
        (300_000_000, .megabytes500),
        (500_000_000, .megabytes500),
        (999_999_999, .gigabyte1),
        (1_000_000_000, .gigabyte1),
        (5_000_000_000, .gigabyte1),
    ])
    func savedSizeIsMovedToAnOption(saved: Int, expected: HistorySizeLimit) throws {
        try withDefaults { defaults in
            defaults.set(saved, forKey: SettingsKey.historyByteLimit)
            #expect(HistorySettings.storedSizeLimit(in: defaults) == expected)
            let history = ClipboardHistory()
            _ = makeSettings(history: history, defaults: defaults)
            #expect(history.retention.byteLimit == expected.byteLimit)
        }
    }

    @Test func storedRetentionHoldsBothSavedLimits() throws {
        try withDefaults { defaults in
            #expect(HistorySettings.storedRetention(in: defaults) == RetentionPolicy(byteLimit: 1_000_000_000))

            defaults.set(120, forKey: SettingsKey.historyLimit)
            defaults.set(500_000_000, forKey: SettingsKey.historyByteLimit)
            #expect(
                HistorySettings.storedRetention(in: defaults)
                    == RetentionPolicy(entryLimit: 120, byteLimit: 500_000_000))

            defaults.set(5, forKey: SettingsKey.historyLimit)
            defaults.set(300_000_000, forKey: SettingsKey.historyByteLimit)
            #expect(
                HistorySettings.storedRetention(in: defaults)
                    == RetentionPolicy(entryLimit: RetentionPolicy.entryLimitRange.lowerBound, byteLimit: 500_000_000))
        }
    }

    /// The history is loaded with `storedRetention` before the settings apply the saved limits, so both must agree:
    /// loading must not delete more or less than the settings would.
    @Test(arguments: [nil, 0, 100_000_000, 1_000_000_000])
    func storedRetentionIsWhatTheSettingsApply(byteLimit: Int?) throws {
        try withDefaults { defaults in
            defaults.set(300, forKey: SettingsKey.historyLimit)
            if let byteLimit {
                defaults.set(byteLimit, forKey: SettingsKey.historyByteLimit)
            }
            let history = ClipboardHistory(retention: RetentionPolicy(entryLimit: 10, byteLimit: 1))
            _ = makeSettings(history: history, defaults: defaults)
            #expect(history.retention == HistorySettings.storedRetention(in: defaults))
        }
    }

    @Test func sizeLimitShowsTheOptionForTheHistorysByteLimit() throws {
        try withDefaults { defaults in
            let history = ClipboardHistory(retention: RetentionPolicy(byteLimit: 200_000_000))
            let settings = HistorySettings(history: history, defaults: defaults)
            #expect(settings.sizeLimit == .megabytes500)
        }
    }

    @Test func changingOneLimitKeepsTheOther() throws {
        try withDefaults { defaults in
            let history = ClipboardHistory()
            let settings = makeSettings(history: history, defaults: defaults)

            settings.applySizeLimit(.megabytes100)
            settings.applyLimit(300)
            #expect(history.retention == RetentionPolicy(entryLimit: 300, byteLimit: 100_000_000))

            settings.applySizeLimit(.megabytes500)
            #expect(history.retention == RetentionPolicy(entryLimit: 300, byteLimit: 500_000_000))
        }
    }

    @Test func sizeLimitAboveTheHistoryNeedsNoConfirmation() throws {
        try withDefaults { defaults in
            let history = makeHistory()
            let settings = makeSettings(history: history, defaults: defaults)

            let change = settings.proposeSizeLimit(.megabytes100)

            #expect(change == LimitChange(limit: .megabytes100, removedCount: 0, freedBytes: 0))
            #expect(!change.needsConfirmation)
            // Proposing changes nothing.
            #expect(history.retention.byteLimit == 1_000_000_000)
            #expect(defaults.object(forKey: SettingsKey.historyByteLimit) == nil)
        }
    }

    @Test func removingTheSizeLimitNeedsNoConfirmation() throws {
        try withDefaults { defaults in
            let settings = makeSettings(history: makeHistory(), defaults: defaults)
            settings.applySizeLimit(.megabytes100)
            #expect(!settings.proposeSizeLimit(.noLimit).needsConfirmation)
        }
    }

    /// The options are far larger than a test history, so this checks the forecast that `proposeSizeLimit` uses
    /// with a byte limit that removes entries.
    @Test func forecastCountsTheOldestEntriesAndTheirBytes() throws {
        try withDefaults { defaults in
            let history = makeHistory()
            let settings = makeSettings(history: history, defaults: defaults)

            let change = settings.forecast("small", under: history.retention.withByteLimit(20))

            // 20 bytes keep the 3 newest entries of 6 bytes.
            #expect(change == LimitChange(limit: "small", removedCount: 7, freedBytes: 42))
            #expect(change.needsConfirmation)
            #expect(history.entries.count == 10)
        }
    }

    @Test func forecastOfAnEmptyHistoryRemovesNothing() throws {
        try withDefaults { defaults in
            let history = ClipboardHistory()
            let settings = makeSettings(history: history, defaults: defaults)
            let change = settings.forecast(1, under: history.retention.withByteLimit(0))
            #expect(change == LimitChange(limit: 1, removedCount: 0, freedBytes: 0))
        }
    }
}
