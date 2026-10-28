import AppKit
import Foundation
import Testing

@testable import ShowMyCopy

/// The history limit in effect when the monitor first read the pasteboard.
@MainActor
final class LimitAtFirstRead {
    var value: Int?
}

@MainActor
struct AppContainerTests {
    /// On the container's clock, so the age limit measures entries against the same time as the monitor.
    private let store = ClipboardHistory(
        retention: RetentionPolicy(entryLimit: ClipboardHistory.limitRange.upperBound),
        now: { ContainerFactory.date })
    private let pasteboard = FakePasteboard()
    private let sleeper = ManualSleeper()
    private let workspace = FakeNotifications()
    private let distributed = FakeNotifications()
    private let settingsWindow = SettingsWindowSpy()
    private let start = ContainerFactory.date

    /// Runs `body` with a container built from fakes and an empty UserDefaults suite that is removed afterwards.
    private func withContainer(
        savedLimit: Int? = nil,
        savesPasswords: Bool? = nil,
        _ body: (AppContainer) throws -> Void
    ) throws {
        let suiteName = "ShowMyCopyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        if let savedLimit {
            defaults.set(savedLimit, forKey: SettingsKey.historyLimit)
        }
        if let savesPasswords {
            defaults.set(savesPasswords, forKey: SettingsKey.savePasswords)
        }
        let services = ContainerFactory.services(
            pasteboard: pasteboard,
            now: { [start] in start },
            sleep: { [sleeper] duration in await sleeper.sleep(for: duration) },
            workspace: workspace,
            distributed: distributed,
            settingsWindow: settingsWindow
        )
        let container = AppContainer(history: .unsaved(store), services: services, defaults: defaults)
        defer {
            container.monitor.stop()
            sleeper.wakeAll()
        }
        try body(container)
    }

    private func fillStore(withEntries count: Int) {
        for index in 0..<count {
            store.record(text: "item \(index)", sourceApp: nil, at: start + Double(index))
        }
    }

    @Test func buildingTheContainerChangesNothing() throws {
        fillStore(withEntries: 15)
        pasteboard.copy("fresh")

        try withContainer(savedLimit: 10) { container in
            #expect(store.limit == ClipboardHistory.limitRange.upperBound)
            #expect(store.entries.count == 15)
            #expect(pasteboard.stringReadCount == 0)
            #expect(pasteboard.dataReadCount == 0)
            #expect(workspace.observedNames.isEmpty)
            #expect(distributed.observedNames.isEmpty)
            #expect(!container.monitor.isPolling)
            #expect(settingsWindow.showCount == 0)
        }
    }

    @Test func startAppliesTheStoredLimitBeforeTheFirstPoll() throws {
        fillStore(withEntries: 15)
        pasteboard.copy("fresh")
        let limitAtFirstRead = LimitAtFirstRead()
        pasteboard.whileReadingString = { [store] _ in
            limitAtFirstRead.value = store.limit
        }

        try withContainer(savedLimit: 10) { container in
            container.start()

            #expect(limitAtFirstRead.value == 10)
            #expect(container.historySettings.limit == 10)
            #expect(store.entries.count == 10)
            #expect(store.entries.first?.text == "fresh")
            #expect(container.monitor.isPolling)
            #expect(!workspace.observedNames.isEmpty)
            #expect(!distributed.observedNames.isEmpty)
        }
    }

    /// A saved history may still hold passwords from a session in which removing them from disk failed.
    @Test func startRemovesSavedPasswordsWhenSavingThemIsOff() throws {
        store.record(text: "hunter2", sourceApp: nil, at: start - 10, concealed: true, expiresAt: start + 600)
        store.record(text: "plain", sourceApp: nil, at: start - 5)
        store.markCurrentSkipped()
        pasteboard.copy("plain")

        try withContainer(savesPasswords: false) { container in
            container.start()
            #expect(store.entries.map(\.text) == ["plain"])
        }
    }

    @Test func startKeepsSavedPasswordsWhenSavingThemIsOn() throws {
        store.record(text: "hunter2", sourceApp: nil, at: start - 10, concealed: true, expiresAt: start + 600)
        store.markCurrentSkipped()
        pasteboard.copy("hunter2", markers: [PasteboardMarker.concealed])

        try withContainer(savesPasswords: true) { container in
            container.start()
            #expect(store.entries.map(\.text) == ["hunter2"])
        }
    }

    @Test func toggleHistoryClearsStalePausesAndListsTheLatestCopy() throws {
        try withContainer { container in
            container.start()
            // The unlock notification was missed, so the monitor still thinks the screen is locked.
            container.monitor.pause(for: .screenLocked)
            pasteboard.copy("just copied")

            container.toggleHistory()

            #expect(container.monitor.pauseReasons.isEmpty)
            #expect(container.monitor.isPolling)
            #expect(container.historyWindow.isVisible)
            let selected = try #require(container.historyWindow.model.selectedEntry)
            #expect(selected.text == "just copied")

            container.toggleHistory()
            #expect(!container.historyWindow.isVisible)
        }
    }

    @Test func toggleHistoryCatchesUpBeforeShowing() throws {
        try withContainer { container in
            // Copied before the monitor's next poll, here before it ever polled.
            pasteboard.copy("just copied")

            container.toggleHistory()

            #expect(container.historyWindow.model.items.map(\.text) == ["just copied"])
        }
    }

    @Test func hideHistoryClosesTheWindow() throws {
        try withContainer { container in
            container.toggleHistory()
            #expect(container.historyWindow.isVisible)

            container.historyWindow.hide()
            #expect(!container.historyWindow.isVisible)
        }
    }

    @Test func userAwayHidesTheHistory() throws {
        try withContainer { container in
            container.start()
            container.toggleHistory()
            #expect(container.historyWindow.isVisible)

            workspace.post(NSWorkspace.willSleepNotification)
            #expect(!container.historyWindow.isVisible)
            #expect(container.monitor.pauseReasons == [.systemSleep])

            workspace.post(NSWorkspace.didWakeNotification)
            container.toggleHistory()
            distributed.post(SystemActivityObserver.screenIsLockedNotification)
            #expect(!container.historyWindow.isVisible)
        }
    }

    @Test func settingsWindowIsBuiltFromTheContainersObjects() throws {
        try withContainer { container in
            let settings = try #require(settingsWindow.settings)
            #expect(settings.store === store)
            #expect(settings.history === container.historySettings)
            #expect(settings.passwords === container.passwordSettings)
            #expect(settings.storage === container.settings.storage)

            container.showSettings()
            #expect(settingsWindow.showCount == 1)
        }
    }

    @Test func monitorFollowsThePasswordSettings() throws {
        try withContainer { container in
            container.start()
            container.passwordSettings.savesPasswords = true
            pasteboard.copy("hunter2", markers: [PasteboardMarker.concealed])
            container.monitor.poll()
            let password = try #require(store.entries.first)
            #expect(password.isConcealed)
            #expect(password.expiresAt == start + PasswordLifetime.default.timeInterval)
        }
    }

    @Test func turningOffSavePasswordsRemovesConcealedEntries() throws {
        try withContainer { container in
            container.passwordSettings.savesPasswords = true
            store.record(text: "plain", sourceApp: nil, at: start)
            store.record(text: "hunter2", sourceApp: nil, at: start + 1, concealed: true, expiresAt: start + 600)

            container.passwordSettings.savesPasswords = false

            #expect(store.entries.map(\.text) == ["plain"])
        }
    }
}
