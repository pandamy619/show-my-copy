import Foundation
import Observation

/// Settings → General → Open at login: whether the app opens when the user logs in.
///
/// Off unless the user turns it on: the app never adds itself to the login items. The state lives in macOS only
/// (System Settings → General → Login Items, where the user can change it too), so it is read again every time
/// Settings open or the app comes back to the front, and never saved by the app.
@MainActor
@Observable
final class LaunchAtLoginSettings {
    /// A change that did not happen. Shown under the toggle until the next change, or until Settings close.
    enum Problem: Equatable {
        case couldNotTurnOn
        case couldNotTurnOff
    }

    @ObservationIgnored private let service: any LoginItemService
    /// Counts reads and changes, so a read that started before a later one cannot overwrite its result.
    @ObservationIgnored private var generation = 0

    /// What macOS said last; nil until the first read.
    private(set) var status: LoginItemStatus?
    /// True while a change is being made; the toggle waits for it.
    private(set) var isChanging = false
    private(set) var problem: Problem?
    /// True from the first launch's Settings until they close: a line next to the toggle offers it, once.
    private(set) var suggestsTurningOn = false

    init(service: any LoginItemService) {
        self.service = service
    }

    /// Whether the toggle is on. An app waiting for approval counts as on: the user asked for it, and the note
    /// under the toggle says what is missing.
    var isOn: Bool {
        switch status {
        case .enabled, .requiresApproval:
            true
        case .notRegistered, .notFound, nil:
            false
        }
    }

    /// macOS opens the app at login only once the user allows it in Login Items.
    var needsApproval: Bool {
        status == .requiresApproval
    }

    /// The toggle can be used once the status is known and no change is under way.
    var canChange: Bool {
        status != nil && !isChanging
    }

    /// Whether to show the first launch's line offering the toggle. Not once it is on.
    var showsSuggestion: Bool {
        suggestsTurningOn && status != nil && !isOn
    }

    /// Settings opened: start without an old problem and read what macOS says now.
    func settingsOpened() async {
        problem = nil
        await refresh()
    }

    /// Settings closed: the suggestion was shown once, and an old problem is not shown again.
    func settingsClosed() {
        suggestsTurningOn = false
        problem = nil
    }

    /// Offers the toggle in the Settings shown on the first launch.
    func suggestOnce() {
        suggestsTurningOn = true
    }

    /// Reads the status again, for example when the user comes back from System Settings.
    func refresh() async {
        // A change reads the status when it is done.
        guard !isChanging else {
            return
        }
        generation += 1
        let read = generation
        let status = await service.status()
        guard read == generation else {
            return
        }
        self.status = status
    }

    /// Turns opening at login on or off. A problem is shown only when the app is not in the state asked for
    /// afterwards: turning on can end in `.requiresApproval`, which the approval note explains instead.
    func setOn(_ isOn: Bool) async {
        guard canChange, isOn != self.isOn else {
            return
        }
        isChanging = true
        problem = nil
        // A read still under way started before this change; its result is dropped. No other read or change
        // starts until this one is done.
        generation += 1
        var failed = false
        do {
            if isOn {
                try await service.register()
            } else {
                try await service.unregister()
            }
        } catch {
            failed = true
            if isOn {
                AppLogger.app.error("Opening at login could not be turned on")
            } else {
                AppLogger.app.error("Opening at login could not be turned off")
            }
        }
        let status = await service.status()
        isChanging = false
        self.status = status
        if failed && self.isOn != isOn {
            problem = isOn ? .couldNotTurnOn : .couldNotTurnOff
        }
    }

    /// Opens System Settings → General → Login Items.
    func openLoginItems() {
        service.openSystemSettings()
    }
}
