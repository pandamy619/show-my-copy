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
    }

    nonisolated static let defaultInterval: Duration = .milliseconds(500)
    nonisolated static let maximumTextBytes = 1_048_576

    private let pasteboard: any PasteboardReading
    private let history: ClipboardHistory
    private let interval: Duration
    private let frontmostApp: @MainActor () -> SourceApp?
    private let now: @MainActor () -> Date
    private var lastChangeCount: Int?
    private var pollTask: Task<Void, Never>?
    private var isStarted = false
    private(set) var pauseReasons: Set<PauseReason> = []

    init(
        pasteboard: any PasteboardReading,
        history: ClipboardHistory,
        interval: Duration = ClipboardMonitor.defaultInterval,
        frontmostApp: @escaping @MainActor () -> SourceApp? = { SourceApp.frontmost() },
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.pasteboard = pasteboard
        self.history = history
        self.interval = interval
        self.frontmostApp = frontmostApp
        self.now = now
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
        updatePolling()
    }

    /// Stops polling while the Mac sleeps or the screen is locked. Polling resumes when every reason is cleared.
    func pause(for reason: PauseReason) {
        pauseReasons.insert(reason)
        updatePolling()
    }

    func resume(for reason: PauseReason) {
        pauseReasons.remove(reason)
        updatePolling()
    }

    private func updatePolling() {
        let shouldPoll = isStarted && pauseReasons.isEmpty
        if shouldPoll, pollTask == nil {
            poll()
            pollTask = Task { [weak self, interval] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard let self, !Task.isCancelled else {
                        return
                    }
                    self.poll()
                }
            }
        } else if !shouldPoll, let pollTask {
            pollTask.cancel()
            self.pollTask = nil
        }
    }

    /// Checks the pasteboard once. The first call records whatever is on the pasteboard at launch.
    func poll() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else {
            return
        }
        // Text that was copied before launch came from an unknown app, not from the one in front now.
        let isFirstPoll = lastChangeCount == nil
        lastChangeCount = changeCount

        let types = Set(pasteboard.types.map(\.rawValue))
        guard types.isDisjoint(with: PasteboardMarker.skipped) else {
            AppLogger.clipboard.debug("Skipped an item marked as concealed, transient or auto-generated")
            return
        }
        guard let text = pasteboard.string(), !text.isEmpty else {
            return
        }
        guard text.utf8.count <= Self.maximumTextBytes else {
            AppLogger.clipboard.info("Skipped text larger than \(Self.maximumTextBytes, privacy: .public) bytes")
            return
        }
        history.record(text: text, sourceApp: isFirstPoll ? nil : frontmostApp(), at: now())
    }
}
