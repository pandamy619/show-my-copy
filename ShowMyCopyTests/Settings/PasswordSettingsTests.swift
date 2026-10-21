import Foundation
import Testing

@testable import ShowMyCopy

@MainActor
struct PasswordSettingsTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// Runs `body` with an empty UserDefaults suite that is removed afterwards.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "ShowMyCopyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    private func makeSettings(history: ClipboardHistory? = nil, defaults: UserDefaults) -> PasswordSettings {
        PasswordSettings(history: history ?? ClipboardHistory(), defaults: defaults, now: { [start] in start })
    }

    @Test func passwordsAreNotSavedByDefault() throws {
        try withDefaults { defaults in
            let settings = makeSettings(defaults: defaults)
            #expect(!settings.savesPasswords)
            #expect(settings.lifetime == .tenMinutes)
            #expect(settings.policy == PasswordPolicy(savesPasswords: false, lifetime: 600))
            #expect(PasswordPolicy.default == settings.policy)
        }
    }

    @Test func lifetimeOptions() {
        #expect(PasswordLifetime.allCases.map(\.timeInterval) == [60, 600, 3600])
        #expect(PasswordLifetime.default == .tenMinutes)
    }

    @Test func choicesPersistAcrossInstances() throws {
        try withDefaults { defaults in
            let first = makeSettings(defaults: defaults)
            first.savesPasswords = true
            first.lifetime = .oneHour

            let second = makeSettings(defaults: defaults)
            #expect(second.savesPasswords)
            #expect(second.lifetime == .oneHour)
            #expect(second.policy == PasswordPolicy(savesPasswords: true, lifetime: 3600))
        }
    }

    @Test(arguments: [0, 59, 601, -1])
    func unknownSavedLifetimeFallsBackToDefault(saved: Int) throws {
        try withDefaults { defaults in
            defaults.set(saved, forKey: SettingsKey.passwordLifetime)
            #expect(makeSettings(defaults: defaults).lifetime == .tenMinutes)
        }
    }

    @Test func savedValuesOfWrongTypeAreIgnored() throws {
        try withDefaults { defaults in
            defaults.set("yes", forKey: SettingsKey.savePasswords)
            defaults.set("long", forKey: SettingsKey.passwordLifetime)
            let settings = makeSettings(defaults: defaults)
            #expect(!settings.savesPasswords)
            #expect(settings.lifetime == .tenMinutes)
        }
    }

    @Test func turningSavingOffRemovesConcealedEntriesRightAway() throws {
        try withDefaults { defaults in
            let history = ClipboardHistory()
            let settings = makeSettings(history: history, defaults: defaults)
            settings.savesPasswords = true
            history.record(text: "secret", sourceApp: nil, at: start, concealed: true, expiresAt: start + 600)
            history.record(text: "plain", sourceApp: nil, at: start + 1)

            settings.savesPasswords = false
            #expect(history.entries.map(\.text) == ["plain"])
            #expect(!PasswordSettings(history: history, defaults: defaults).savesPasswords)
        }
    }

    @Test func turningSavingOnKeepsEntries() throws {
        try withDefaults { defaults in
            let history = ClipboardHistory()
            history.record(text: "plain", sourceApp: nil, at: start)
            let settings = makeSettings(history: history, defaults: defaults)
            settings.savesPasswords = true
            #expect(history.entries.map(\.text) == ["plain"])
        }
    }

    @Test func shorterLifetimeAppliesToSavedPasswords() throws {
        try withDefaults { defaults in
            let history = ClipboardHistory()
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
