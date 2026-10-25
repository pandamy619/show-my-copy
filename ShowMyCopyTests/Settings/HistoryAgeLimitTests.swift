import Foundation
import Testing

@testable import ShowMyCopy

/// The age limit is saved, read back and applied like the other limits. It is off until Settings offers it.
@MainActor
struct HistoryAgeLimitTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeHistory(now: Date) -> InMemoryHistoryStore {
        let history = InMemoryHistoryStore(retention: .default, now: { now })
        history.record(text: "old", sourceApp: nil, at: start)
        history.record(text: "recent", sourceApp: nil, at: start + 7 * 3600)
        return history
    }

    @Test func offWhenNothingIsSaved() throws {
        try TemporaryFolder.withDefaults { defaults in
            #expect(HistoryAgeLimit.default == .off)
            #expect(RetentionLimit.age.stored(in: defaults) == .off)
            #expect(HistorySettings.storedRetention(in: defaults).maxAge == nil)
            // Reading the default does not save it, so a later default applies to everyone who never chose.
            #expect(defaults.object(forKey: SettingsKey.historyMaxAge) == nil)
        }
    }

    @Test func aSavedAgeLimitIsReadInSecondsAndZeroIsOff() throws {
        try TemporaryFolder.withDefaults { defaults in
            defaults.set(8 * 3600, forKey: SettingsKey.historyMaxAge)
            #expect(RetentionLimit.age.stored(in: defaults) == .after(.seconds(8 * 3600)))
            #expect(HistorySettings.storedRetention(in: defaults).maxAge == .seconds(8 * 3600))

            defaults.set(0, forKey: SettingsKey.historyMaxAge)
            #expect(RetentionLimit.age.stored(in: defaults) == .off)
        }
    }

    @Test func ignoresSavedValuesOfWrongTypeOrSign() throws {
        try TemporaryFolder.withDefaults { defaults in
            for value: Any in ["long", ["a": 1], -1, Int.min] {
                defaults.set(value, forKey: SettingsKey.historyMaxAge)
                #expect(RetentionLimit.age.stored(in: defaults) == .default)
            }
        }
    }

    @Test func applyingAnAgeLimitSavesItAndRemovesOlderEntries() throws {
        try TemporaryFolder.withDefaults { defaults in
            let now = start + 9 * 3600
            let history = makeHistory(now: now)
            let settings = HistorySettings(history: history, defaults: defaults, now: { now })
            let eightHours = HistoryAgeLimit.after(.seconds(8 * 3600))

            let change = settings.propose(eightHours, for: .age)
            #expect(change == LimitChange(limit: eightHours, removedCount: 1, freedBytes: 3))
            #expect(history.entries.count == 2)

            settings.apply(eightHours, for: .age)
            #expect(history.entries.map(\.text) == ["recent"])
            #expect(settings.value(of: .age) == eightHours)
            #expect(defaults.object(forKey: SettingsKey.historyMaxAge) as? Int == 8 * 3600)

            settings.apply(.off, for: .age)
            #expect(history.retention.maxAge == nil)
            // Saved, so a later default does not override the choice.
            #expect(defaults.object(forKey: SettingsKey.historyMaxAge) as? Int == 0)
        }
    }

    @Test func theAgeLimitKeepsTheOtherLimits() throws {
        try TemporaryFolder.withDefaults { defaults in
            let history = InMemoryHistoryStore()
            let settings = HistorySettings(history: history, defaults: defaults, now: { Date() })
            settings.apply(300, for: .entries)
            settings.apply(.megabytes100, for: .size)
            settings.apply(.after(.seconds(3600)), for: .age)
            #expect(
                history.retention
                    == RetentionPolicy(entryLimit: 300, byteLimit: 100_000_000, maxAge: .seconds(3600)))
            #expect(history.retention == HistorySettings.storedRetention(in: defaults))
        }
    }

    @Test func storedLimitsAreAppliedTogether() throws {
        try TemporaryFolder.withDefaults { defaults in
            defaults.set(3600, forKey: SettingsKey.historyMaxAge)
            let history = InMemoryHistoryStore()
            HistorySettings(history: history, defaults: defaults, now: { Date() }).applyStoredLimits()
            #expect(history.retention == RetentionPolicy(byteLimit: 1_000_000_000, maxAge: .seconds(3600)))
        }
    }

    @Test func anAgeLimitOfNoTimeIsOff() {
        #expect(HistoryAgeLimit(maxAge: nil) == .off)
        #expect(HistoryAgeLimit(maxAge: .zero) == .off)
        #expect(HistoryAgeLimit.after(.zero).maxAge == nil)
        #expect(HistoryAgeLimit(maxAge: .seconds(60)) == .after(.seconds(60)))
        #expect(HistoryAgeLimit.after(.seconds(60)).seconds == 60)
        #expect(HistoryAgeLimit.off.seconds == 0)
    }
}
