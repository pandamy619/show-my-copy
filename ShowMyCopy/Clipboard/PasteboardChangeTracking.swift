/// What the history window and the entry copier need from the clipboard monitor: catch up with the pasteboard,
/// skip the app's own writes, clear pause reasons a missed notification left behind and keep App Nap away while the
/// window is open.
///
/// `ClipboardMonitor` is the only conforming type in the app. The protocol keeps the window and the copier from
/// depending on how the monitor polls, and lets tests check the order of calls.
@MainActor
protocol PasteboardChangeTracking: AnyObject {
    /// Checks the pasteboard once and records a change made since the last check.
    func poll()

    /// Marks a pasteboard change made by this app as seen, so it is not recorded again as a copy.
    func acknowledge(changeCount: Int)

    /// The user did something only a person at the awake, unlocked Mac can do.
    func userIsActive()

    /// The history window opened or closed (see `PollingActivityPolicy`).
    func historyWindowOpened(_ isOpen: Bool)
}
