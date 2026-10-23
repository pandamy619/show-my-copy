/// UserDefaults keys for app settings. Clipboard contents are never stored in UserDefaults.
enum SettingsKey {
    static let historyLimit = "history.limit"
    /// The history size limit in bytes, 0 for no limit.
    static let historyByteLimit = "history.byteLimit"
    static let didShowSettingsOnFirstLaunch = "launch.didShowSettings"
    static let savePasswords = "passwords.save"
    static let passwordLifetime = "passwords.lifetime"
}
