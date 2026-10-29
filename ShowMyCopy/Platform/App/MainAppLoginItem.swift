import ServiceManagement

/// The app itself as a login item, through `SMAppService.mainApp` (macOS 13 and later). It needs no helper app and no
/// entitlement, and works in the sandbox. macOS lists the app in System Settings → General → Login Items, where the
/// user can turn it off again.
///
/// The service is looked up on each call instead of being kept: `SMAppService` is not `Sendable`, and the calls run
/// off the main actor.
struct MainAppLoginItem: LoginItemService {
    func status() async -> LoginItemStatus {
        Self.status(of: SMAppService.mainApp.status)
    }

    func register() async throws(LoginItemError) {
        do {
            try SMAppService.mainApp.register()
        } catch {
            // The caller logs a constant message; the system's error is not needed to tell the user.
            throw .failed
        }
    }

    func unregister() async throws(LoginItemError) {
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            throw .failed
        }
    }

    @MainActor
    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func status(of status: SMAppService.Status) -> LoginItemStatus {
        switch status {
        case .notRegistered:
            .notRegistered
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .notFound
        @unknown default:
            // A status added later: the app cannot tell whether it opens at login, so the toggle shows off and
            // turning it on registers again.
            .notFound
        }
    }
}
