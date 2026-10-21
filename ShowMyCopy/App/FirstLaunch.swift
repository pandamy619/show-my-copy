import Foundation

/// Remembers whether Settings were shown on the first launch.
///
/// The app has no Dock or menu bar icon, so on the first launch nothing would appear at all. Settings explain how
/// to open the history and how to quit.
struct FirstLaunch {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// True until `settingsWereShown()` is called.
    var shouldShowSettings: Bool {
        !defaults.bool(forKey: SettingsKey.didShowSettingsOnFirstLaunch)
    }

    /// Call after Settings were shown, so later launches start quietly.
    func settingsWereShown() {
        defaults.set(true, forKey: SettingsKey.didShowSettingsOnFirstLaunch)
    }
}
