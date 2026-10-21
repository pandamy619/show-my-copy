import Foundation

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

    private let pasteboard: any PasteboardReading
    private let history: ClipboardHistory
    private let interval: Duration
    private let frontmostApp: @MainActor () -> SourceApp?
    private let now: @MainActor () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let activity: any PollingActivity
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
        activity: any PollingActivity = ProcessPollingActivity()
    ) {
        self.pasteboard = pasteboard
        self.history = history
        self.interval = interval
        self.frontmostApp = frontmostApp
        self.now = now
        self.sleep = sleep
        self.activity = activity
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
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else {
            if isStarted, pauseReasons.isEmpty {
                // Nothing changed while the monitor was away, so the next change happens while it is watching.
                sourceOfNextChangeIsUnknown = false
            }
            return
        }
        let text = readText()
        // `readText` makes separate calls, so another app can replace the item between them, for example a
        // password manager writing a concealed item after the marker check. Then the text may belong to a newer
        // item than the markers. Record nothing and keep the old count, so the next poll reads the new item again.
        guard pasteboard.changeCount == changeCount else {
            AppLogger.clipboard.debug("The pasteboard changed while it was read; reading it again on the next poll")
            return
        }
        // Text copied before launch, during sleep or while the screen was locked (for example on another device
        // through Universal Clipboard) came from an unknown app, not from the one in front now.
        let sourceIsUnknown = sourceOfNextChangeIsUnknown
        sourceOfNextChangeIsUnknown = false
        lastChangeCount = changeCount
        guard let text else {
            history.markCurrentSkipped()
            return
        }
        history.record(text: text, sourceApp: sourceIsUnknown ? nil : frontmostApp(), at: now())
    }

    /// Returns the text of the current item, or nil when the item must not be recorded.
    private func readText() -> String? {
        guard !hasSkippedMarker() else {
            return nil
        }
        guard let text = pasteboard.string(), !text.isEmpty else {
            return nil
        }
        // An app can add a marker after the text without a new change count, so look at the markers again.
        guard !hasSkippedMarker() else {
            return nil
        }
        guard text.utf8.count <= Self.maximumTextBytes else {
            AppLogger.clipboard.info("Skipped text larger than \(Self.maximumTextBytes, privacy: .public) bytes")
            return nil
        }
        return text
    }

    private func hasSkippedMarker() -> Bool {
        let types = Set(pasteboard.types.map(\.rawValue))
        guard types.isDisjoint(with: PasteboardMarker.skipped) else {
            AppLogger.clipboard.debug("Skipped an item marked as concealed, transient or auto-generated")
            return true
        }
        return false
    }
}
