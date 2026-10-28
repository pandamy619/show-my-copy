import AppKit
import Foundation
import Testing

@testable import ShowMyCopy

/// The age limit as the app runs it: 8 hours unless the user chose otherwise, applied at launch, while the app idles,
/// after wake and unlock, and in the open history window. The clock is a fake that moves only when a test moves it.
@MainActor
struct AppContainerAgeLimitTests {
    private let start = ContainerFactory.date
    private let clock = ManualDate(ContainerFactory.date)
    private let pasteboard = FakePasteboard()
    private let workspace = FakeNotifications()
    private let distributed = FakeNotifications()
    private let store: InMemoryHistoryStore

    init() {
        store = InMemoryHistoryStore(
            retention: RetentionPolicy(entryLimit: RetentionPolicy.entryLimitRange.upperBound),
            now: clock.read)
    }

    /// Runs `body` with a container built from fakes and an empty UserDefaults suite that is removed afterwards.
    private func withContainer(savedMaxAge: Int? = nil, _ body: (AppContainer) throws -> Void) throws {
        let suiteName = "ShowMyCopyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        if let savedMaxAge {
            defaults.set(savedMaxAge, forKey: SettingsKey.historyMaxAge)
        }
        let services = ContainerFactory.services(
            pasteboard: pasteboard,
            now: clock.read,
            workspace: workspace,
            distributed: distributed
        )
        let container = AppContainer(history: .unsaved(store), services: services, defaults: defaults)
        defer { container.monitor.stop() }
        try body(container)
    }

    @Test func launchRemovesEntriesCopiedEightHoursAgoOrEarlierByDefault() throws {
        store.record(text: "eight hours", sourceApp: nil, at: start - 8 * 3600)
        store.record(text: "just under", sourceApp: nil, at: start - 8 * 3600 + 1)
        store.markCurrentSkipped()

        try withContainer { container in
            container.start()
            #expect(container.settings.history.value(of: .age) == .after(.seconds(8 * 3600)))
            #expect(store.entries.map(\.text) == ["just under"])
        }
    }

    @Test func launchKeepsOldEntriesWhenTheUserTurnedTheAgeLimitOff() throws {
        store.record(text: "a month ago", sourceApp: nil, at: start - 30 * 86_400)
        store.markCurrentSkipped()

        try withContainer(savedMaxAge: 0) { container in
            container.start()
            #expect(container.settings.history.value(of: .age) == .off)
            #expect(store.entries.map(\.text) == ["a month ago"])
        }
    }

    /// Nothing polls while the Mac sleeps. Polling starts again with a poll on wake, so what expired meanwhile goes
    /// before the history can be shown.
    @Test func entriesThatExpiredDuringSleepGoOnWake() throws {
        try withContainer { container in
            container.start()
            pasteboard.copy("copied")
            container.monitor.poll()

            workspace.post(NSWorkspace.willSleepNotification)
            clock.advance(by: 9 * 3600)
            #expect(store.entries.map(\.text) == ["copied"])

            workspace.post(NSWorkspace.didWakeNotification)
            #expect(store.entries.isEmpty)
        }
    }

    @Test func entriesThatExpiredWhileTheScreenWasLockedGoOnUnlock() throws {
        try withContainer { container in
            container.start()
            pasteboard.copy("copied")
            container.monitor.poll()

            distributed.post(SystemActivityObserver.screenIsLockedNotification)
            clock.advance(by: 9 * 3600)
            #expect(store.entries.map(\.text) == ["copied"])

            distributed.post(SystemActivityObserver.screenIsUnlockedNotification)
            #expect(store.entries.isEmpty)
        }
    }

    /// The open history window lists what the history holds, so an entry that expires leaves the list.
    @Test func theOpenHistoryWindowDropsEntriesThatExpire() throws {
        try withContainer { container in
            container.start()
            pasteboard.copy("old")
            container.monitor.poll()
            clock.advance(by: 3600)
            pasteboard.copy("recent")
            container.monitor.poll()
            container.toggleHistory()
            let model = container.historyWindow.model
            #expect(model.items.map(\.text) == ["recent", "old"])

            clock.advance(by: 7 * 3600)
            container.monitor.poll()
            #expect(container.historyWindow.isVisible)
            #expect(model.items.map(\.text) == ["recent"])

            clock.advance(by: 3600)
            container.monitor.poll()
            #expect(model.items.isEmpty)
        }
    }

    /// An age limit chosen in Settings that removes entries waits for confirmation, then applies at once.
    @Test func aLimitChosenInSettingsIsAppliedAndSaved() throws {
        try withContainer { container in
            container.start()
            pasteboard.copy("copied")
            container.monitor.poll()
            clock.advance(by: 2 * 3600)

            let draft = LimitDraft(settings: container.settings.history, limit: .age)
            draft.value = .after(.seconds(3600))
            #expect(draft.pending?.removedCount == 1)
            #expect(store.entries.map(\.text) == ["copied"])
            draft.confirm()
            #expect(store.entries.isEmpty)
            #expect(store.retention.maxAge == .seconds(3600))
        }
    }
}
