import Foundation
import Testing

@testable import ShowMyCopy

@MainActor
struct HistorySettingsTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// Runs `body` with an empty UserDefaults suite that is removed afterwards.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "ShowMyCopyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    private func makeHistory(withEntries count: Int) -> ClipboardHistory {
        let history = ClipboardHistory(limit: ClipboardHistory.limitRange.upperBound)
        for index in 0..<count {
            history.record(text: "item \(index)", sourceApp: nil, at: start + Double(index))
        }
        return history
    }

    @Test func usesDefaultLimitWhenNothingIsSaved() throws {
        try withDefaults { defaults in
            let history = ClipboardHistory(limit: 200)
            let settings = HistorySettings(history: history, defaults: defaults)
            #expect(settings.limit == ClipboardHistory.defaultLimit)
            #expect(history.limit == ClipboardHistory.defaultLimit)
        }
    }

    @Test func appliesSavedLimitToHistoryOnInit() throws {
        try withDefaults { defaults in
            defaults.set(120, forKey: SettingsKey.historyLimit)
            let history = ClipboardHistory()
            _ = HistorySettings(history: history, defaults: defaults)
            #expect(history.limit == 120)
        }
    }

    @Test(arguments: [(0, 10), (-5, 10), (10, 10), (1000, 1000), (99_999, 1000)])
    func savedLimitIsClamped(saved: Int, expected: Int) throws {
        try withDefaults { defaults in
            defaults.set(saved, forKey: SettingsKey.historyLimit)
            #expect(HistorySettings.storedLimit(in: defaults) == expected)
            #expect(HistorySettings(history: ClipboardHistory(), defaults: defaults).limit == expected)
        }
    }

    @Test func ignoresSavedValueOfWrongType() throws {
        try withDefaults { defaults in
            defaults.set("lots", forKey: SettingsKey.historyLimit)
            #expect(HistorySettings.storedLimit(in: defaults) == ClipboardHistory.defaultLimit)
            defaults.set(["a": 1], forKey: SettingsKey.historyLimit)
            #expect(HistorySettings.storedLimit(in: defaults) == ClipboardHistory.defaultLimit)
        }
    }

    @Test func appliedLimitPersistsAcrossInstances() throws {
        try withDefaults { defaults in
            let first = HistorySettings(history: ClipboardHistory(), defaults: defaults)
            first.applyLimit(300)
            #expect(defaults.object(forKey: SettingsKey.historyLimit) as? Int == 300)

            let history = ClipboardHistory()
            let second = HistorySettings(history: history, defaults: defaults)
            #expect(second.limit == 300)
            #expect(history.limit == 300)
        }
    }

    @Test func applySavesClampedValue() throws {
        try withDefaults { defaults in
            let settings = HistorySettings(history: ClipboardHistory(), defaults: defaults)
            settings.applyLimit(5000)
            #expect(settings.limit == 1000)
            #expect(HistorySettings.storedLimit(in: defaults) == 1000)
        }
    }

    @Test func raisingLimitNeedsNoConfirmation() throws {
        try withDefaults { defaults in
            let settings = HistorySettings(history: makeHistory(withEntries: 30), defaults: defaults)
            let change = settings.proposeLimit(500)
            #expect(change == LimitChange(limit: 500, removedCount: 0))
            #expect(!change.needsConfirmation)
        }
    }

    @Test func loweringLimitAboveEntryCountNeedsNoConfirmation() throws {
        try withDefaults { defaults in
            let settings = HistorySettings(history: makeHistory(withEntries: 15), defaults: defaults)
            #expect(!settings.proposeLimit(20).needsConfirmation)
            #expect(!settings.proposeLimit(15).needsConfirmation)
        }
    }

    @Test func loweringLimitBelowEntryCountNeedsConfirmation() throws {
        try withDefaults { defaults in
            let history = makeHistory(withEntries: 40)
            let settings = HistorySettings(history: history, defaults: defaults)
            let change = settings.proposeLimit(25)
            #expect(change == LimitChange(limit: 25, removedCount: 15))
            #expect(change.needsConfirmation)
            // Proposing changes nothing.
            #expect(history.entries.count == 40)
            #expect(settings.limit == ClipboardHistory.defaultLimit)
            #expect(defaults.object(forKey: SettingsKey.historyLimit) == nil)
        }
    }

    @Test func proposalIsClamped() throws {
        try withDefaults { defaults in
            let settings = HistorySettings(history: makeHistory(withEntries: 40), defaults: defaults)
            #expect(settings.proposeLimit(1) == LimitChange(limit: 10, removedCount: 30))
        }
    }

    @Test func applyingLowerLimitTrimsOldestEntries() throws {
        try withDefaults { defaults in
            let history = makeHistory(withEntries: 40)
            let settings = HistorySettings(history: history, defaults: defaults)
            settings.applyLimit(25)
            #expect(history.limit == 25)
            #expect(history.entries.count == 25)
            #expect(history.entries.first?.text == "item 39")
            #expect(history.entries.last?.text == "item 15")
        }
    }
}
