import Foundation
import Testing

@testable import ShowMyCopy

/// The excluded apps as the app runs them: the list in Settings is the one the monitor checks, and it is read from
/// UserDefaults at launch.
@MainActor
struct AppContainerExcludedAppsTests {
    private let pasteboard = FakePasteboard()
    private let store = InMemoryHistoryStore(
        retention: RetentionPolicy(entryLimit: RetentionPolicy.entryLimitRange.upperBound),
        now: { ContainerFactory.date })
    private let front = FrontApp()
    private let running = FakeRunningApps()
    private let textEdit = SourceApp(bundleIdentifier: "com.apple.TextEdit", name: "TextEdit")

    /// The app a test puts in front.
    @MainActor
    final class FrontApp {
        var app: SourceApp?
    }

    private func withContainer(defaults: UserDefaults, _ body: (AppContainer) throws -> Void) rethrows {
        let services = ContainerFactory.services(
            pasteboard: pasteboard, frontmostApp: { [front] in front.app }, runningApps: running)
        let container = AppContainer(history: .unsaved(store), services: services, defaults: defaults)
        defer { container.monitor.stop() }
        container.start()
        try body(container)
    }

    @Test func appAddedInSettingsIsSkippedFromTheNextCopy() throws {
        try TestDefaults.with { defaults in
            try withContainer(defaults: defaults) { container in
                front.app = textEdit
                pasteboard.copy("recorded")
                container.monitor.poll()

                running.apps = [textEdit]
                container.settings.excludedApps.add(try #require(container.settings.excludedApps.addableApps().first))
                pasteboard.copy("private note")
                container.monitor.poll()

                #expect(store.entries.map(\.text) == ["recorded"])
                #expect(store.currentEntryID == nil)
            }
        }
    }

    @Test func savedListAppliesAfterARelaunch() throws {
        try TestDefaults.with { defaults in
            defaults.set(
                [["bundleIdentifier": "com.apple.TextEdit", "name": "TextEdit"]], forKey: SettingsKey.excludedApps)
            withContainer(defaults: defaults) { container in
                #expect(container.settings.excludedApps.apps.map(\.name) == ["TextEdit"])
                // The first look after launch has no known source; the copy after it has.
                container.monitor.poll()
                front.app = textEdit
                pasteboard.copy("private note")
                container.monitor.poll()

                #expect(!store.entries.map(\.text).contains("private note"))
            }
        }
    }
}
