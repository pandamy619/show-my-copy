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
    private let store: ClipboardHistory

    init() {
        store = ClipboardHistory(
            retention: RetentionPolicy(entryLimit: ClipboardHistory.limitRange.upperBound),
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
            #expect(container.historySettings.value(of: .age) == .after(.seconds(8 * 3600)))
            #expect(store.entries.map(\.text) == ["just under"])
        }
    }

    @Test func launchKeepsOldEntriesWhenTheUserTurnedTheAgeLimitOff() throws {
        store.record(text: "a month ago", sourceApp: nil, at: start - 30 * 86_400)
        store.markCurrentSkipped()

        try withContainer(savedMaxAge: 0) { container in
            container.start()
            #expect(container.historySettings.value(of: .age) == .off)
            #expect(store.entries.map(\.text) == ["a month ago"])
        }
    }
}
