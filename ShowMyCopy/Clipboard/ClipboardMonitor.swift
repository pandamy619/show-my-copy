import AppKit

/// Records new copies in the history. It coordinates the types that do the work and decides little itself:
///
/// - `schedule` says when to look at the pasteboard. On each look the monitor compares `changeCount` and reads the
///   item only when the count changed; `PasteboardSnapshotReader` says what the item is.
/// - The monitor decides who copied (the app in front, or nobody known after a pause) and what the password settings
///   allow, and records text and rich text itself.
/// - `capture` records images and files at once and fills in their data, sizes and thumbnails in the background. The
///   monitor goes on reading meanwhile, so no copy is missed while an image is saved.
/// - `expiry` removes expired passwords on every look, and `clearedClipboard` may take the entry copied just before
///   an emptied clipboard for a password.
@MainActor
final class ClipboardMonitor: PasteboardChangeTracking {
    private let pasteboard: any PasteboardReading
    private let reader: PasteboardSnapshotReader
    private let history: any HistoryStore
    private let schedule: PollingSchedule
    private let expiry: PasswordExpiry
    private let clearedClipboard: ClearedClipboardCheck
    /// Records images and files and fills them in. Without it images are not read and files keep their icons.
    private let capture: CaptureEnrichment?
    private let frontmostApp: @MainActor () -> SourceApp?
    private let now: @MainActor () -> Date
    private let passwordPolicy: @MainActor () -> PasswordPolicy
    private var lastChangeCount: Int?
    /// True until the monitor has looked at the pasteboard while running. A change found then was made before
    /// launch or while the monitor was stopped or paused, so the app in front now did not necessarily make it.
    private var sourceOfNextChangeIsUnknown = true

    init(
        pasteboard: any PasteboardReading,
        history: any HistoryStore,
        schedule: PollingSchedule,
        expiry: PasswordExpiry,
        clearedClipboard: ClearedClipboardCheck,
        capture: CaptureEnrichment?,
        frontmostApp: @escaping @MainActor () -> SourceApp?,
        now: @escaping @MainActor () -> Date,
        passwordPolicy: @escaping @MainActor () -> PasswordPolicy
    ) {
        self.pasteboard = pasteboard
        self.reader = PasteboardSnapshotReader(
            pasteboard: pasteboard,
            contentReaders: PasteboardSnapshotReader.standardReaders(readsImages: capture?.readsImages == true))
        self.history = history
        self.schedule = schedule
        self.expiry = expiry
        self.clearedClipboard = clearedClipboard
        self.capture = capture
        self.frontmostApp = frontmostApp
        self.now = now
        self.passwordPolicy = passwordPolicy
        schedule.tick = { [weak self] in
            self?.poll()
        }
    }

    var isPolling: Bool {
        schedule.isPolling
    }

    var pauseReasons: Set<PollingSchedule.PauseReason> {
        schedule.pauseReasons
    }

    func start() {
        schedule.start()
    }

    func stop() {
        sourceOfNextChangeIsUnknown = true
        schedule.stop()
    }

    /// Stops polling while the Mac sleeps or the screen is locked. Polling resumes when every reason is cleared.
    func pause(for reason: PollingSchedule.PauseReason) {
        sourceOfNextChangeIsUnknown = true
        schedule.pause(for: reason)
    }

    func resume(for reason: PollingSchedule.PauseReason) {
        schedule.resume(for: reason)
    }

    /// Clears every pause reason. Call it when the user does something only a person at the unlocked Mac can do,
    /// such as pressing the history shortcut: then the Mac is awake, the screen is unlocked and the session is
    /// active, even if a notification saying so was missed.
    func userIsActive() {
        schedule.resumeAll()
    }

    /// The history window opened or closed: while it is open, polling keeps App Nap away (`PollingActivityPolicy`).
    func historyWindowOpened(_ isOpen: Bool) {
        schedule.setHistoryWindowOpen(isOpen)
    }

    /// The user switched to another app, which usually comes with copying and pasteboard changes.
    func userSwitchedApps() {
        schedule.noteActivity()
    }

    /// Marks a pasteboard change made by this app as seen, so it is not recorded again as a copy
    /// from whichever app is in front.
    func acknowledge(changeCount: Int) {
        lastChangeCount = changeCount
    }

    /// Checks the pasteboard once. The first call records whatever is on the pasteboard at launch.
    func poll() {
        expiry.removeExpired()
        let date = now()
        let changeCount = pasteboard.changeCount
        if changeCount == lastChangeCount {
            if schedule.isWatching {
                // Nothing changed while the monitor was away, so the next change happens while it is watching.
                sourceOfNextChangeIsUnknown = false
            }
            // An app that empties the clipboard may fill it a moment later without a new change count, so an
            // emptied clipboard is looked at once more.
            guard clearedClipboard.isWaiting(at: changeCount) else {
                return
            }
        }
        // Text copied before launch, during sleep or while the screen was locked (for example on another device
        // through Universal Clipboard) came from an unknown app, not from the one in front now.
        let sourceApp = sourceOfNextChangeIsUnknown ? nil : frontmostApp()
        let policy = passwordPolicy()
        let item = reader.read(
            fromPasswordManager: PasswordManager.isPasswordManager(bundleIdentifier: sourceApp?.bundleIdentifier),
            savesPasswords: policy.savesPasswords
        )
        // The reader makes separate calls, so another app can replace the item between them, for example a
        // password manager writing a concealed item after the marker check. Then the text may belong to a newer
        // item than the markers. Record nothing and keep the old count, so the next poll reads the new item again.
        guard pasteboard.changeCount == changeCount else {
            AppLogger.clipboard.debug("The pasteboard changed while it was read; reading it again on the next poll")
            return
        }
        if item == .cleared, clearedClipboard.isWaiting(at: changeCount) {
            clearedClipboard.confirm(policy: policy)
            return
        }
        // A new change, or the emptied clipboard was filled: either way it was not left empty.
        clearedClipboard.dismiss()
        // More copies are likely soon: keep the timer on time for a while.
        schedule.noteActivity()
        let copy = CopyEvent(sourceApp: sourceApp, date: date, isFirstRead: lastChangeCount == nil)
        sourceOfNextChangeIsUnknown = false
        lastChangeCount = changeCount
        handle(item, copy: copy, changeCount: changeCount, policy: policy)
    }

    /// Whether the data or thumbnails of a recorded copy are still being made.
    var isEnriching: Bool {
        capture?.isEnriching == true
    }

    /// Waits until the data and thumbnails of every copy recorded so far are made and in the history, for example
    /// before the app quits. Copies go on being recorded meanwhile.
    func finishEnriching() async {
        await capture?.drain()
    }

    private func handle(_ item: CapturedItem, copy: CopyEvent, changeCount: Int, policy: PasswordPolicy) {
        switch item {
        case .skipped:
            history.markCurrentSkipped()
        case .image(let image):
            if let capture {
                capture.record(image, as: copy)
            } else {
                history.markCurrentSkipped()
            }
        case .cleared:
            clearedClipboard.clipboardWasEmptied(changeCount: changeCount, at: copy.date)
        case .content(.files(let files), isSecret: false) where capture != nil:
            capture?.record(files, as: copy)
        case .content(let content, let isSecret):
            record(content, isSecret: isSecret, copy: copy, policy: policy)
        }
    }

    private func record(_ content: ClipboardContent, isSecret: Bool, copy: CopyEvent, policy: PasswordPolicy) {
        if copy.isFirstRead, let newestID = history.markNewestCurrent(ifItHolds: content) {
            // At launch the pasteboard usually still holds the newest entry. Nothing says it was copied again,
            // so keep its date and source app. A password marker still conceals it; an earlier expiry stays.
            if isSecret {
                history.conceal(id: newestID, expiresAt: copy.date + policy.lifetime)
            }
            return
        }
        if isSecret {
            history.record(
                content, sourceApp: copy.sourceApp, at: copy.date, concealed: true,
                expiresAt: copy.date + policy.lifetime)
        } else {
            history.record(content, sourceApp: copy.sourceApp, at: copy.date)
        }
    }
}
