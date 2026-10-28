import Foundation
import Testing

@testable import ShowMyCopy

@MainActor
struct PasswordSettingsTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// Runs `body` with an empty UserDefaults suite that is removed afterwards.
    private func makeSettings(history: InMemoryHistoryStore? = nil, defaults: UserDefaults) -> PasswordSettings {
        PasswordSettings(
            history: .unsaved(history ?? InMemoryHistoryStore()), defaults: defaults, now: { [start] in start })
    }

    @Test func passwordsAreNotSavedByDefault() throws {
        try TestDefaults.with { defaults in
            let settings = makeSettings(defaults: defaults)
            #expect(!settings.savesPasswords)
            #expect(settings.lifetime == .tenMinutes)
            #expect(settings.policy == PasswordPolicy(savesPasswords: false, lifetime: 600))
            #expect(PasswordPolicy.default == settings.policy)
        }
    }

    /// A damaged copy of the history may hold passwords; the storage the app was given deletes it.
    @Test func turningSavingOffDeletesTheDamagedCopyThroughTheStorage() throws {
        try TestDefaults.with { defaults in
            let storage = UnsavedHistoryStorage()
            let settings = PasswordSettings(
                history: AppHistory(store: InMemoryHistoryStore(), storage: storage), defaults: defaults,
                now: { [start] in start })
            settings.savesPasswords = true
            #expect(storage.damagedHistoryDeletions == 0)
            settings.savesPasswords = false
            #expect(storage.damagedHistoryDeletions == 1)
        }
    }

    @Test func lifetimeOptions() {
        #expect(PasswordLifetime.allCases.map(\.timeInterval) == [60, 600, 3600])
        #expect(PasswordLifetime.default == .tenMinutes)
    }

    @Test func choicesPersistAcrossInstances() throws {
        try TestDefaults.with { defaults in
            let first = makeSettings(defaults: defaults)
            first.savesPasswords = true
            first.lifetime = .oneHour

            let second = makeSettings(defaults: defaults)
            #expect(second.savesPasswords)
            #expect(second.lifetime == .oneHour)
            #expect(second.policy == PasswordPolicy(savesPasswords: true, lifetime: 3600))
        }
    }

    @Test func storedSavesPasswordsReadsTheSavedChoice() throws {
        try TestDefaults.with { defaults in
            #expect(!PasswordSettings.storedSavesPasswords(in: defaults))
            makeSettings(defaults: defaults).savesPasswords = true
            #expect(PasswordSettings.storedSavesPasswords(in: defaults))
            makeSettings(defaults: defaults).savesPasswords = false
            #expect(!PasswordSettings.storedSavesPasswords(in: defaults))
        }
    }

    @Test func storedSavesPasswordsIgnoresAValueOfTheWrongType() throws {
        try TestDefaults.with { defaults in
            defaults.set("yes", forKey: SettingsKey.savePasswords)
            #expect(!PasswordSettings.storedSavesPasswords(in: defaults))
            #expect(!makeSettings(defaults: defaults).savesPasswords)
        }
    }

    @Test(arguments: [0, 59, 601, -1])
    func unknownSavedLifetimeFallsBackToDefault(saved: Int) throws {
        try TestDefaults.with { defaults in
            defaults.set(saved, forKey: SettingsKey.passwordLifetime)
            #expect(makeSettings(defaults: defaults).lifetime == .tenMinutes)
        }
    }

    @Test func savedValuesOfWrongTypeAreIgnored() throws {
        try TestDefaults.with { defaults in
            defaults.set("yes", forKey: SettingsKey.savePasswords)
            defaults.set("long", forKey: SettingsKey.passwordLifetime)
            let settings = makeSettings(defaults: defaults)
            #expect(!settings.savesPasswords)
            #expect(settings.lifetime == .tenMinutes)
        }
    }

    @Test func turningSavingOffRemovesConcealedEntriesRightAway() throws {
        try TestDefaults.with { defaults in
            let history = InMemoryHistoryStore()
            let settings = makeSettings(history: history, defaults: defaults)
            settings.savesPasswords = true
            history.record(text: "secret", sourceApp: nil, at: start, concealed: true, expiresAt: start + 600)
            history.record(text: "plain", sourceApp: nil, at: start + 1)

            settings.savesPasswords = false
            #expect(history.entries.map(\.text) == ["plain"])
            #expect(!makeSettings(history: history, defaults: defaults).savesPasswords)
        }
    }

    @Test func turningSavingOnKeepsEntries() throws {
        try TestDefaults.with { defaults in
            let history = InMemoryHistoryStore()
            history.record(text: "plain", sourceApp: nil, at: start)
            let settings = makeSettings(history: history, defaults: defaults)
            settings.savesPasswords = true
            #expect(history.entries.map(\.text) == ["plain"])
        }
    }

    @Test func shorterLifetimeAppliesToSavedPasswords() throws {
        try TestDefaults.with { defaults in
            let history = InMemoryHistoryStore()
            let settings = makeSettings(history: history, defaults: defaults)
            settings.savesPasswords = true
            history.record(text: "secret", sourceApp: nil, at: start, concealed: true, expiresAt: start + 600)

            settings.lifetime = .oneMinute
            #expect(history.entries.first?.expiresAt == start + 60)

            // A longer lifetime does not keep a password longer than promised when it was copied.
            settings.lifetime = .oneHour
            #expect(history.entries.first?.expiresAt == start + 60)
        }
    }
}
