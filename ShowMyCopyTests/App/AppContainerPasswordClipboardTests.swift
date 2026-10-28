import AppKit
import Foundation
import Testing

@testable import ShowMyCopy

/// Saved passwords as the app runs them: when one leaves the history, it leaves the clipboard too, if the clipboard
/// still holds exactly that password. The clock is a fake that moves only when a test moves it.
@MainActor
struct AppContainerPasswordClipboardTests {
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

    /// Runs `body` with a started container that saves passwords for a minute.
    private func withContainer(_ body: (AppContainer) throws -> Void) throws {
        let suiteName = "ShowMyCopyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: SettingsKey.savePasswords)
        defaults.set(PasswordLifetime.oneMinute.rawValue, forKey: SettingsKey.passwordLifetime)
        let services = ContainerFactory.services(
            pasteboard: pasteboard, now: clock.read, workspace: workspace, distributed: distributed)
        let container = AppContainer(history: .unsaved(store), services: services, defaults: defaults)
        defer { container.monitor.stop() }
        container.start()
        try body(container)
    }

    /// Copies a marked password and lets the monitor record it.
    private func copyPassword(in container: AppContainer) {
        pasteboard.copy("hunter2", markers: [PasteboardMarker.concealed])
        container.monitor.poll()
    }

    @Test func anExpiredPasswordLeavesTheClipboard() throws {
        try withContainer { container in
            copyPassword(in: container)
            let passwordChange = pasteboard.changeCount

            clock.advance(by: 60)
            container.monitor.poll()

            #expect(store.entries.isEmpty)
            #expect(pasteboard.clearedChangeCounts == [passwordChange])
        }
    }

    @Test func turningSavingPasswordsOffEmptiesTheClipboard() throws {
        try withContainer { container in
            copyPassword(in: container)
            let passwordChange = pasteboard.changeCount

            container.passwordSettings.savesPasswords = false

            #expect(store.entries.isEmpty)
            #expect(pasteboard.clearedChangeCounts == [passwordChange])
        }
    }

    @Test func aPasswordCopiedBackLeavesTheClipboardWhenItExpires() throws {
        try withContainer { container in
            copyPassword(in: container)
            pasteboard.copy("plain")
            container.monitor.poll()
            let password = try #require(store.entries.first { $0.isConcealed })
            #expect(container.copier.copy(password))
            let copiedChange = pasteboard.changeCount

            clock.advance(by: 60)
            container.monitor.poll()

            #expect(store.entries.map(\.text) == ["plain"])
            #expect(pasteboard.clearedChangeCounts == [copiedChange])
        }
    }
}
