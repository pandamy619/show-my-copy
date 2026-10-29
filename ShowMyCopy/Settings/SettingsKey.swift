/// UserDefaults keys for app settings. Clipboard contents are never stored in UserDefaults.
enum SettingsKey {
    static let historyLimit = "history.limit"
    /// The history size limit in bytes, 0 for no limit.
    static let historyByteLimit = "history.byteLimit"
    /// How long entries are kept after they were last copied, in seconds, 0 for no age limit.
    static let historyMaxAge = "history.maxAge"
    static let didShowSettingsOnFirstLaunch = "launch.didShowSettings"
    static let savePasswords = "passwords.save"
    static let passwordLifetime = "passwords.lifetime"
    /// The apps whose copies are never recorded: an array of dictionaries with a bundle identifier and a name.
    static let excludedApps = "capture.excludedApps"
}
