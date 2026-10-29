import Foundation
import Testing

@testable import ShowMyCopy

@MainActor
struct HistorySettingsTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    /// The clock of the history and the settings: shortly after the entries, so the age limit removes none of them.
    private var now: Date { start + 60 }

    /// Runs `body` with an empty UserDefaults suite that is removed afterwards.
    /// Settings as the app sets them up when it starts: the saved limit is applied to the history.
    private func makeSettings(history: InMemoryHistoryStore, defaults: UserDefaults) -> HistorySettings {
        let settings = HistorySettings(history: history, defaults: defaults, now: { [now] in now })
        settings.applyStoredLimits()
        return settings
    }

    private func makeHistory(withEntries count: Int) -> InMemoryHistoryStore {
        let history = InMemoryHistoryStore(
            retention: RetentionPolicy(entryLimit: RetentionPolicy.entryLimitRange.upperBound), now: { [now] in now })
        for index in 0..<count {
            history.record(text: "item \(index)", sourceApp: nil, at: start + Double(index))
        }
        return history
    }

    @Test func usesDefaultLimitWhenNothingIsSaved() throws {
        try TestDefaults.with { defaults in
            let history = InMemoryHistoryStore(limit: 200)
            let settings = makeSettings(history: history, defaults: defaults)
            #expect(settings.limit == RetentionPolicy.defaultEntryLimit)
            #expect(history.limit == RetentionPolicy.defaultEntryLimit)
        }
    }

    @Test func creatingSettingsLeavesTheHistoryAlone() throws {
        try TestDefaults.with { defaults in
            defaults.set(10, forKey: SettingsKey.historyLimit)
            let history = makeHistory(withEntries: 15)

            let settings = HistorySettings(history: history, defaults: defaults, now: { [now] in now })

            #expect(history.limit == RetentionPolicy.entryLimitRange.upperBound)
            #expect(history.entries.count == 15)
            #expect(settings.limit == RetentionPolicy.entryLimitRange.upperBound)
        }
    }

    @Test func applyingTheStoredLimitTrimsTheHistory() throws {
        try TestDefaults.with { defaults in
            defaults.set(10, forKey: SettingsKey.historyLimit)
            let history = makeHistory(withEntries: 15)
            let settings = HistorySettings(history: history, defaults: defaults, now: { [now] in now })

            settings.applyStoredLimits()

            #expect(settings.limit == 10)
            #expect(history.limit == 10)
            #expect(history.entries.map(\.text) == (5..<15).reversed().map { "item \($0)" })
            // Applying the saved value does not save it again.
            #expect(defaults.object(forKey: SettingsKey.historyLimit) as? Int == 10)
        }
    }

    @Test func appliesSavedLimitToHistory() throws {
        try TestDefaults.with { defaults in
            defaults.set(120, forKey: SettingsKey.historyLimit)
            let history = InMemoryHistoryStore()
            _ = makeSettings(history: history, defaults: defaults)
            #expect(history.limit == 120)
        }
    }

    @Test(arguments: [(0, 10), (-5, 10), (10, 10), (1000, 1000), (99_999, 1000)])
    func savedLimitIsClamped(saved: Int, expected: Int) throws {
        try TestDefaults.with { defaults in
            defaults.set(saved, forKey: SettingsKey.historyLimit)
            #expect(RetentionLimit.entries.stored(in: defaults) == expected)
            #expect(makeSettings(history: InMemoryHistoryStore(), defaults: defaults).limit == expected)
        }
    }

    @Test func ignoresSavedValueOfWrongType() throws {
        try TestDefaults.with { defaults in
            defaults.set("lots", forKey: SettingsKey.historyLimit)
            #expect(RetentionLimit.entries.stored(in: defaults) == RetentionPolicy.defaultEntryLimit)
            defaults.set(["a": 1], forKey: SettingsKey.historyLimit)
            #expect(RetentionLimit.entries.stored(in: defaults) == RetentionPolicy.defaultEntryLimit)
        }
    }

    @Test func appliedLimitPersistsAcrossInstances() throws {
        try TestDefaults.with { defaults in
            let first = makeSettings(history: InMemoryHistoryStore(), defaults: defaults)
            first.apply(300, for: .entries)
            #expect(defaults.object(forKey: SettingsKey.historyLimit) as? Int == 300)

            let history = InMemoryHistoryStore()
            let second = makeSettings(history: history, defaults: defaults)
            #expect(second.limit == 300)
            #expect(history.limit == 300)
        }
    }

    @Test func applySavesClampedValue() throws {
        try TestDefaults.with { defaults in
            let settings = makeSettings(history: InMemoryHistoryStore(), defaults: defaults)
            settings.apply(5000, for: .entries)
            #expect(settings.limit == 1000)
            #expect(RetentionLimit.entries.stored(in: defaults) == 1000)
        }
    }

    @Test func raisingLimitNeedsNoConfirmation() throws {
        try TestDefaults.with { defaults in
            let settings = makeSettings(history: makeHistory(withEntries: 30), defaults: defaults)
            let change = settings.propose(500, for: .entries)
            #expect(change == LimitChange(limit: 500, removedCount: 0, freedBytes: 0, keptPinnedCount: 0))
            #expect(!change.needsConfirmation)
        }
    }

    @Test func loweringLimitAboveEntryCountNeedsNoConfirmation() throws {
        try TestDefaults.with { defaults in
            let settings = makeSettings(history: makeHistory(withEntries: 15), defaults: defaults)
            #expect(!settings.propose(20, for: .entries).needsConfirmation)
            #expect(!settings.propose(15, for: .entries).needsConfirmation)
        }
    }

    @Test func loweringLimitBelowEntryCountNeedsConfirmation() throws {
        try TestDefaults.with { defaults in
            let history = makeHistory(withEntries: 40)
            let settings = makeSettings(history: history, defaults: defaults)
            let change = settings.propose(25, for: .entries)
            // Items 0 to 9 take 6 bytes each, items 10 to 14 take 7.
            #expect(change == LimitChange(limit: 25, removedCount: 15, freedBytes: 95, keptPinnedCount: 0))
            #expect(change.needsConfirmation)
            // Proposing changes nothing.
            #expect(history.entries.count == 40)
            #expect(settings.limit == RetentionPolicy.defaultEntryLimit)
            #expect(defaults.object(forKey: SettingsKey.historyLimit) == nil)
        }
    }

    @Test func proposalIsClamped() throws {
        try TestDefaults.with { defaults in
            let settings = makeSettings(history: makeHistory(withEntries: 40), defaults: defaults)
            #expect(
                settings.propose(1, for: .entries)
                    == LimitChange(limit: 10, removedCount: 30, freedBytes: 200, keptPinnedCount: 0))
        }
    }

    @Test func applyingLowerLimitTrimsOldestEntries() throws {
        try TestDefaults.with { defaults in
            let history = makeHistory(withEntries: 40)
            let settings = makeSettings(history: history, defaults: defaults)
            settings.apply(25, for: .entries)
            #expect(history.limit == 25)
            #expect(history.entries.count == 25)
            #expect(history.entries.first?.text == "item 39")
            #expect(history.entries.last?.text == "item 15")
        }
    }
}
