import Foundation

/// Polls the pasteboard and records new text in the history.
///
/// macOS has no notification for pasteboard changes, so the monitor compares `changeCount`
/// on a timer and reads the contents only when the count changes.
@MainActor
final class ClipboardMonitor {
    nonisolated static let defaultInterval: Duration = .milliseconds(500)
    nonisolated static let maximumTextBytes = 1_048_576

    private let pasteboard: any PasteboardReading
    private let history: ClipboardHistory
    private let interval: Duration
    private let frontmostApp: @MainActor () -> SourceApp?
    private let now: @MainActor () -> Date
    private var lastChangeCount: Int?
    private var pollTask: Task<Void, Never>?

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
        guard pollTask == nil else {
            return
        }
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
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Checks the pasteboard once. The first call records whatever is on the pasteboard at launch.
    func poll() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else {
            return
        }
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
        history.record(text: text, sourceApp: frontmostApp(), at: now())
    }
}
