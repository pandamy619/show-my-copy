/// Whether macOS opens the app when the user logs in, as the system reports it. The cases are those of
/// `SMAppService.Status`; `LaunchAtLoginSettings` decides what each one means for Settings.
enum LoginItemStatus: Equatable, Sendable {
    /// The app is not a login item.
    case notRegistered
    /// The app opens at login.
    case enabled
    /// The app is a login item, but the user has to allow it in System Settings → General → Login Items.
    case requiresApproval
    /// The system does not know the app as a login item, for example after it was moved.
    case notFound
}

/// A change to the login item failed. The system's error is not kept: it says nothing the user can act on beyond
/// "it did not work", and the app logs only that.
enum LoginItemError: Error, Equatable {
    case failed
}

/// The app's own login item. The real one is `SMAppService.mainApp` (`MainAppLoginItem`), which the sandbox and the
/// App Store allow without a helper app; tests use a fake.
///
/// The status is never copied into UserDefaults: the user can change it in System Settings at any time, so it is
/// always asked for. Each call asks a system service and can take a moment, so the calls are async and run off the
/// main actor.
protocol LoginItemService: Sendable {
    func status() async -> LoginItemStatus
    /// Makes the app open at login. macOS may still want the user's approval (`.requiresApproval`).
    func register() async throws(LoginItemError)
    /// Stops the app from opening at login.
    func unregister() async throws(LoginItemError)
    /// Opens System Settings → General → Login Items, where the user allows or removes the app.
    @MainActor func openSystemSettings()
}
