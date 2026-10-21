/// UserDefaults keys for app settings. Clipboard contents are never stored in UserDefaults.
enum SettingsKey {
    static let historyLimit = "history.limit"
    static let didShowSettingsOnFirstLaunch = "launch.didShowSettings"
    static let savePasswords = "passwords.save"
    static let passwordLifetime = "passwords.lifetime"
}
