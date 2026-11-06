import Foundation
import Testing

@testable import ShowMyCopy

/// Stands in for the SwiftUI settings window and remembers what the container built it from.
@MainActor
final class SettingsWindowSpy: SettingsWindowShowing {
    /// The page asked for each time the window was shown; nil keeps the one it shows.
    private(set) var shownSections: [SettingsSection?] = []
    var settings: AppSettings?
    var copyText: (@MainActor (String) -> Void)?

    var showCount: Int {
        shownSections.count
    }

    func show(section: SettingsSection?) {
        shownSections.append(section)
    }
}

/// Builds the containers of the tests from fakes, so a new service is added here once instead of in every test
/// file. Every default is a fake: no app is in front, the clock stands still, the polling loop never wakes up on its
/// own, App Nap and notifications are never touched, the screen is unlocked, there are no images or previews,
/// the app is not a login item and may not paste.
@MainActor
enum ContainerFactory {
    static let date = Date(timeIntervalSince1970: 1_790_000_000)

    static func services(
        pasteboard: any PasteboardReading & PasteboardWriting = FakePasteboard(),
        now: @escaping @MainActor () -> Date = { ContainerFactory.date },
        frontmostApp: @escaping @MainActor () -> SourceApp? = { nil },
        sleep: @escaping @Sendable (Duration) async throws -> Void = MonitorFactory.sleepUntilCancelled,
        workspace: any NotificationObserving = FakeNotifications(),
        distributed: any NotificationObserving = FakeNotifications(),
        isScreenLocked: @escaping @MainActor () -> Bool = { false },
        runningApps: any RunningAppsListing = FakeRunningApps(),
        appChooser: any AppChoosing = FakeAppChooser(),
        media: AppServices.Media = .none,
        settingsWindow: SettingsWindowSpy = SettingsWindowSpy(),
        loginItem: FakeLoginItem = FakeLoginItem(),
        paste: AppServices.Paste = .fake()
    ) -> AppServices {
        AppServices(
            pasteboard: pasteboard,
            system: AppServices.System(
                now: now,
                frontmostApp: frontmostApp,
                sleep: sleep,
                pollingActivity: CountingActivity(),
                workspaceNotifications: workspace,
                distributedNotifications: distributed,
                isScreenLocked: isScreenLocked,
                isSessionActive: { true },
                runningApps: runningApps,
                appChooser: appChooser
            ),
            media: media,
            paste: paste,
            memoryReader: NoMemoryUsage(),
            loginItem: loginItem,
            makeSettingsWindow: { settings, copyText in
                settingsWindow.settings = settings
                settingsWindow.copyText = copyText
                return settingsWindow
            }
        )
    }

    /// Runs `body` with an empty UserDefaults suite that is removed afterwards.
    static func withDefaults(_ body: @MainActor (UserDefaults) async throws -> Void) async throws {
        let suiteName = "ShowMyCopyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try await body(defaults)
    }
}
