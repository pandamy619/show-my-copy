import Foundation
import Testing

@testable import ShowMyCopy

private let hour = 3600
private let day = 24 * hour

/// Saved seconds and the option they become. A typed constant: as an inline argument list of arithmetic tuples it
/// takes the type checker too long.
private let savedValuesAndOptions: [(Int, Int)] = [
    (1, 1 * hour), (hour, hour), (hour + 1, 8 * hour), (8 * hour, 8 * hour), (9 * hour, 24 * hour),
    (2 * day, 7 * day), (8 * day, 30 * day), (100 * day, 30 * day), (10_000 * day, 30 * day), (0, 0),
]

/// The age limits Settings offers, how each is named, and how a value it does not offer becomes one it does.
@MainActor
struct HistoryAgeLimitOptionsTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func optionsAreShortestFirstWithOffLast() {
        #expect(
            HistoryAgeLimit.options.map(\.seconds) == [
                hour, 8 * hour, 24 * hour, 7 * day, 30 * day, 0,
            ])
        #expect(HistoryAgeLimit.options.contains(.default))
    }

    @Test func eachOptionIsNamedInHoursBelowAWeekAndInDaysFromAWeek() {
        #expect(
            HistoryAgeLimit.options.map(\.span) == [
                .hours(1), .hours(8), .hours(24), .days(7), .days(30), nil,
            ])
    }

    /// A saved value Settings does not offer becomes the shortest option that keeps entries at least as long, or
    /// the longest option when none does, as the size limit does. 0 stays Off.
    @Test(arguments: savedValuesAndOptions)
    func aSavedValueBecomesAnOption(saved: Int, option: Int) throws {
        try TestDefaults.with { defaults in
            defaults.set(saved, forKey: SettingsKey.historyMaxAge)
            let stored = RetentionLimit.age.stored(in: defaults)
            #expect(stored.seconds == option)
            #expect(HistoryAgeLimit.options.contains(stored))
            #expect(HistorySettings.storedRetention(in: defaults).maxAge == stored.maxAge)
        }
    }

    @Test func aProposedValueBecomesAnOption() throws {
        try TestDefaults.with { defaults in
            let history = InMemoryHistoryStore(retention: .default, now: { [start] in start })
            let settings = HistorySettings(history: history, defaults: defaults, now: { [start] in start })
            #expect(settings.propose(.after(.seconds(90)), for: .age).limit == .after(.seconds(hour)))

            settings.apply(.after(.seconds(90)), for: .age)
            #expect(settings.value(of: .age) == .after(.seconds(hour)))
            #expect(defaults.object(forKey: SettingsKey.historyMaxAge) as? Int == hour)
        }
    }

    /// The picker shows the option for a history whose policy was set to another age, rather than nothing.
    @Test func theValueInEffectShowsAsAnOption() throws {
        try TestDefaults.with { defaults in
            let history = InMemoryHistoryStore(retention: RetentionPolicy(maxAge: .seconds(2 * hour)))
            let settings = HistorySettings(history: history, defaults: defaults, now: { [start] in start })
            #expect(settings.value(of: .age) == .after(.seconds(8 * hour)))
            #expect(LimitDraft(settings: settings, limit: .age).value == .after(.seconds(8 * hour)))
        }
    }
}
