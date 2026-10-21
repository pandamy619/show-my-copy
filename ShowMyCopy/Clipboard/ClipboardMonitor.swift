import AppKit

/// Polls the pasteboard and records new text in the history.
///
/// macOS has no notification for pasteboard changes, so the monitor compares `changeCount`
/// on a timer and reads the contents only when the count changes.
@MainActor
final class ClipboardMonitor {
    enum PauseReason: Hashable, Sendable {
        case systemSleep
        case displaySleep
        case screenLocked
        case sessionInactive
    }

    nonisolated static let defaultInterval: Duration = .milliseconds(500)
    nonisolated static let maximumTextBytes = 1_048_576
    /// How soon after a copy an emptied clipboard counts as a password manager clearing the password it copied.
    /// 1Password and Bitwarden clear after about 90 seconds by default.
    nonisolated static let clearedClipboardWindow: TimeInterval = 180

    /// What the latest pasteboard item turned out to be.
    private enum Item {
        case content(ClipboardContent, isSecret: Bool)
        /// Not recorded: a password while passwords are not saved, a transient, non-text or too large item.
        case skipped
        /// Nothing on the pasteboard: an app, usually a password manager, emptied it.
        case cleared
    }

    private let pasteboard: any PasteboardReading
    private let history: ClipboardHistory
    private let interval: Duration
    private let frontmostApp: @MainActor () -> SourceApp?
    private let now: @MainActor () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let activity: any PollingActivity
    private let passwordPolicy: @MainActor () -> PasswordPolicy
    private var lastChangeCount: Int?
    /// True until the monitor has looked at the pasteboard while running. A change found then was made before
    /// launch or while the monitor was stopped or paused, so the app in front now did not necessarily make it.
    private var sourceOfNextChangeIsUnknown = true
    private var pollTask: Task<Void, Never>?
    private var isStarted = false
    private(set) var pauseReasons: Set<PauseReason> = []

    init(
        pasteboard: any PasteboardReading,
        history: ClipboardHistory,
        interval: Duration = ClipboardMonitor.defaultInterval,
        frontmostApp: @escaping @MainActor () -> SourceApp? = { SourceApp.frontmost() },
        now: @escaping @MainActor () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        activity: any PollingActivity = ProcessPollingActivity(),
        passwordPolicy: @escaping @MainActor () -> PasswordPolicy = { .default }
    ) {
        self.pasteboard = pasteboard
        self.history = history
        self.interval = interval
        self.frontmostApp = frontmostApp
        self.now = now
        self.sleep = sleep
        self.activity = activity
        self.passwordPolicy = passwordPolicy
    }

    var isPolling: Bool {
        pollTask != nil
    }

    func start() {
        isStarted = true
        updatePolling()
    }

    func stop() {
        isStarted = false
        sourceOfNextChangeIsUnknown = true
        updatePolling()
    }

    /// Stops polling while the Mac sleeps or the screen is locked. Polling resumes when every reason is cleared.
    func pause(for reason: PauseReason) {
        pauseReasons.insert(reason)
        sourceOfNextChangeIsUnknown = true
        updatePolling()
    }

    func resume(for reason: PauseReason) {
        pauseReasons.remove(reason)
        updatePolling()
    }

    /// Clears every pause reason. Call it when the user does something only a person at the unlocked Mac can do,
    /// such as pressing the history shortcut: then the Mac is awake, the screen is unlocked and the session is
    /// active, even if a notification saying so was missed.
    func userIsActive() {
        guard !pauseReasons.isEmpty else {
            return
        }
        pauseReasons.removeAll()
        updatePolling()
    }

    private func updatePolling() {
        let shouldPoll = isStarted && pauseReasons.isEmpty
        if shouldPoll, pollTask == nil {
            activity.begin()
            poll()
            pollTask = Task { [weak self, interval, sleep] in
                while !Task.isCancelled {
                    try? await sleep(interval)
                    guard let self, !Task.isCancelled else {
                        return
                    }
                    self.poll()
                }
            }
        } else if !shouldPoll, let pollTask {
            pollTask.cancel()
            self.pollTask = nil
            activity.end()
        }
    }

    /// Marks a pasteboard change made by this app as seen, so it is not recorded again as a copy
    /// from whichever app is in front.
    func acknowledge(changeCount: Int) {
        lastChangeCount = changeCount
    }

    /// Checks the pasteboard once. The first call records whatever is on the pasteboard at launch.
    func poll() {
        let date = now()
        // Checked on every poll, not only on a change, so a password leaves the history on time.
        history.removeExpired(at: date)
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else {
            if isStarted, pauseReasons.isEmpty {
                // Nothing changed while the monitor was away, so the next change happens while it is watching.
                sourceOfNextChangeIsUnknown = false
            }
            return
        }
        // Text copied before launch, during sleep or while the screen was locked (for example on another device
        // through Universal Clipboard) came from an unknown app, not from the one in front now.
        let sourceApp = sourceOfNextChangeIsUnknown ? nil : frontmostApp()
        let policy = passwordPolicy()
        let item = readItem(
            fromPasswordManager: PasswordManager.isPasswordManager(bundleIdentifier: sourceApp?.bundleIdentifier),
            savesPasswords: policy.savesPasswords
        )
        // `readItem` makes separate calls, so another app can replace the item between them, for example a
        // password manager writing a concealed item after the marker check. Then the text may belong to a newer
        // item than the markers. Record nothing and keep the old count, so the next poll reads the new item again.
        guard pasteboard.changeCount == changeCount else {
            AppLogger.clipboard.debug("The pasteboard changed while it was read; reading it again on the next poll")
            return
        }
        sourceOfNextChangeIsUnknown = false
        lastChangeCount = changeCount
        switch item {
        case .skipped:
            history.markCurrentSkipped()
        case .cleared:
            clipboardWasCleared(at: date, policy: policy)
        case .content(let content, let isSecret):
            if isSecret {
                history.record(
                    content, sourceApp: sourceApp, at: date, concealed: true, expiresAt: date + policy.lifetime)
            } else {
                history.record(content, sourceApp: sourceApp, at: date)
            }
        }
    }

    /// Password managers empty the clipboard a while after copying a password. A password copied without a marker,
    /// for example from a browser extension, is recognized only then: if the entry recorded last is still on the
    /// clipboard and was copied a short time ago, it is most likely that password.
    private func clipboardWasCleared(at date: Date, policy: PasswordPolicy) {
        defer { history.markCurrentSkipped() }
        guard let currentID = history.currentEntryID,
            let current = history.entries.first(where: { $0.id == currentID }),
            date.timeIntervalSince(current.date) <= Self.clearedClipboardWindow
        else {
            return
        }
        if policy.savesPasswords {
            history.conceal(id: currentID, expiresAt: date + policy.lifetime)
            AppLogger.clipboard.debug("The clipboard was cleared soon after a copy; the entry is now concealed")
        } else {
            history.remove(id: currentID)
            AppLogger.clipboard.debug("The clipboard was cleared soon after a copy; the entry was removed")
        }
    }

    /// Reads the current item. The text of a password is read only when passwords are saved.
    private func readItem(fromPasswordManager: Bool, savesPasswords: Bool) -> Item {
        let markers = currentMarkers()
        if markers.contentTypes.isEmpty {
            return .cleared
        }
        var isSecret = fromPasswordManager || markers.isSecret
        guard !shouldSkip(markers, isSecret: isSecret, savesPasswords: savesPasswords) else {
            return .skipped
        }
        let text = pasteboard.string()
        // An app can add a marker after the text without a new change count, so look at the markers again.
        let markersAfterText = currentMarkers()
        isSecret = isSecret || markersAfterText.isSecret
        guard !shouldSkip(markersAfterText, isSecret: isSecret, savesPasswords: savesPasswords) else {
            return .skipped
        }
        guard let text, !text.isEmpty else {
            // Empty text, or a text type without text, is what an app leaves when it empties the clipboard.
            return markersAfterText.contentTypes.isSubset(of: Self.textTypes) ? .cleared : .skipped
        }
        guard text.utf8.count <= Self.maximumTextBytes else {
            AppLogger.clipboard.info("Skipped text larger than \(Self.maximumTextBytes, privacy: .public) bytes")
            return .skipped
        }
        return .content(.text(text), isSecret: isSecret)
    }

    private func shouldSkip(_ markers: Markers, isSecret: Bool, savesPasswords: Bool) -> Bool {
        if markers.isAlwaysSkipped {
            AppLogger.clipboard.debug("Skipped an item marked as transient or auto-generated")
            return true
        }
        if isSecret, !savesPasswords {
            AppLogger.clipboard.debug("Skipped a secret item")
            return true
        }
        return false
    }

    /// Types that hold plain text. An item with only these types and no text is an emptied clipboard.
    private static let textTypes: Set<NSPasteboard.PasteboardType> = [
        .string, NSPasteboard.PasteboardType("NSStringPboardType"),
    ]

    private struct Markers {
        var isSecret: Bool
        var isAlwaysSkipped: Bool
        /// The types that hold data, without the nspasteboard.org markers.
        var contentTypes: Set<NSPasteboard.PasteboardType>
    }

    private func currentMarkers() -> Markers {
        let types = Set(pasteboard.types)
        let names = Set(types.map(\.rawValue))
        let markerNames = PasteboardMarker.secret.union(PasteboardMarker.alwaysSkipped).union([PasteboardMarker.source])
        return Markers(
            isSecret: !names.isDisjoint(with: PasteboardMarker.secret),
            isAlwaysSkipped: !names.isDisjoint(with: PasteboardMarker.alwaysSkipped),
            contentTypes: types.filter { !markerNames.contains($0.rawValue) }
        )
    }
}
