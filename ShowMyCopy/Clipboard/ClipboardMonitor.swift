import AppKit

/// Polls the pasteboard and records new copies in the history.
///
/// macOS has no notification for pasteboard changes, so the monitor compares `changeCount`
/// on a timer and reads the contents only when the count changes. It decides when to read, who copied and what
/// the password settings allow; `PasteboardSnapshotReader` decides what the item is.
///
/// A copied image is stored by `imageIngestor` off the main actor before it is recorded, and copied photo and video
/// files get their thumbnails from `fileThumbnailIngestor` the same way. Until then the monitor reads no further
/// change, so copies are recorded in the order they were made.
@MainActor
final class ClipboardMonitor: PasteboardChangeTracking {
    enum PauseReason: Hashable, Sendable {
        case systemSleep
        case displaySleep
        case screenLocked
        case sessionInactive
    }

    nonisolated static let defaultInterval: Duration = .milliseconds(500)
    /// The largest text recorded, in UTF-8 bytes. `TextContentReader` checks it.
    nonisolated static let maximumTextBytes = TextContentReader.defaultMaximumBytes
    /// How soon after a copy an emptied clipboard counts as a password manager clearing the password it copied.
    /// 1Password and Bitwarden clear after about 90 seconds by default.
    nonisolated static let clearedClipboardWindow: TimeInterval = 180

    private let pasteboard: any PasteboardReading
    private let reader: PasteboardSnapshotReader
    private let history: any HistoryStore
    private let interval: Duration
    private let frontmostApp: @MainActor () -> SourceApp?
    private let now: @MainActor () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let activity: any PollingActivity
    private let passwordPolicy: @MainActor () -> PasswordPolicy
    /// Stores copied images. Without it images are not read.
    private let imageIngestor: ImageIngestor?
    /// Makes thumbnails of copied photo and video files. Without it files are recorded at once, with their icons.
    private let fileThumbnailIngestor: FileThumbnailIngestor?
    /// Storing the image or the file thumbnails read last, or nil.
    private var pendingIngestion: Task<Void, Never>?
    private var lastChangeCount: Int?
    /// True until the monitor has looked at the pasteboard while running. A change found then was made before
    /// launch or while the monitor was stopped or paused, so the app in front now did not necessarily make it.
    private var sourceOfNextChangeIsUnknown = true
    private var pollTask: Task<Void, Never>?
    private var isStarted = false
    private(set) var pauseReasons: Set<PauseReason> = []

    init(
        pasteboard: any PasteboardReading,
        history: any HistoryStore,
        interval: Duration = ClipboardMonitor.defaultInterval,
        frontmostApp: @escaping @MainActor () -> SourceApp? = { SourceApp.frontmost() },
        now: @escaping @MainActor () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        activity: any PollingActivity = ProcessPollingActivity(),
        passwordPolicy: @escaping @MainActor () -> PasswordPolicy = { .default },
        imageIngestor: ImageIngestor? = nil,
        fileThumbnailIngestor: FileThumbnailIngestor? = nil
    ) {
        self.pasteboard = pasteboard
        self.reader = PasteboardSnapshotReader(
            pasteboard: pasteboard,
            contentReaders: PasteboardSnapshotReader.standardReaders(readsImages: imageIngestor != nil))
        self.imageIngestor = imageIngestor
        self.fileThumbnailIngestor = fileThumbnailIngestor
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
        guard pendingIngestion == nil else {
            // The next change is read once the image or files are recorded, so it ends up above them.
            return
        }
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
        let copy = Copy(
            sourceApp: sourceApp, date: date, isFirstRead: lastChangeCount == nil, changeCount: changeCount)
        sourceOfNextChangeIsUnknown = false
        lastChangeCount = changeCount
        switch item {
        case .skipped:
            history.markCurrentSkipped()
        case .image(let image):
            storeImage(image, copy: copy)
        case .cleared:
            clipboardWasCleared(at: date, policy: policy)
        case .content(.files(let files), isSecret: false) where fileThumbnailIngestor != nil:
            storeFileThumbnails(files, copy: copy)
        case .content(let content, let isSecret):
            record(content, isSecret: isSecret, copy: copy, policy: policy)
        }
    }

    /// When and how the item being recorded was copied.
    private struct Copy {
        let sourceApp: SourceApp?
        let date: Date
        /// The first read after launch: the item may be the newest entry, still on the pasteboard.
        let isFirstRead: Bool
        let changeCount: Int
    }

    private func record(_ content: ClipboardContent, isSecret: Bool, copy: Copy, policy: PasswordPolicy) {
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

    /// Waits until the image or files read last are stored and recorded. For tests and for quitting cleanly.
    func finishStoringImages() async {
        await pendingIngestion?.value
    }

    // MARK: - Images

    /// Stores the image off the main actor, then records it. Nothing is current meanwhile: the pasteboard no longer
    /// holds the entry that was current, and the image is not an entry yet.
    private func storeImage(_ image: CapturedImage, copy: Copy) {
        history.markCurrentSkipped()
        guard let imageIngestor else {
            return
        }
        // Images already in the history, so copying one again writes nothing.
        let known = Dictionary(
            history.entries.compactMap { entry in entry.content.image.map { ($0.contentHash, $0) } },
            uniquingKeysWith: { first, _ in first })
        pendingIngestion = Task { [weak self] in
            let result: Result<IngestedImage, ImageIngestError>
            do throws(ImageIngestError) {
                result = .success(try await imageIngestor.ingest(image, known: known))
            } catch {
                result = .failure(error)
            }
            guard let self else {
                if case .success(let ingested) = result {
                    imageIngestor.discard(ingested)
                }
                return
            }
            self.pendingIngestion = nil
            self.recordImage(result, ingestor: imageIngestor, copy: copy)
        }
    }

    private func recordImage(_ result: Result<IngestedImage, ImageIngestError>, ingestor: ImageIngestor, copy: Copy) {
        let ingested: IngestedImage
        switch result {
        case .success(let value):
            ingested = value
        case .failure(.notAnImage):
            // Logged by the ingestor; nothing to record.
            return
        case .failure(.storageFailed):
            AppLogger.clipboard.error("Could not save a copied image; it is not recorded")
            return
        }
        // This app wrote to the pasteboard meanwhile (an entry was copied back), so the image is no longer there
        // and the entry the user picked must stay on top.
        guard lastChangeCount == copy.changeCount else {
            AppLogger.clipboard.debug("The pasteboard changed while an image was saved; it is not recorded")
            ingestor.discard(ingested)
            return
        }
        // A known image whose entry was removed meanwhile lost its data with it.
        guard ingested.isNew || history.entries.contains(where: { $0.content.image == ingested.reference }) else {
            return
        }
        let content = ClipboardContent.image(ingested.reference)
        if copy.isFirstRead, history.markNewestCurrent(ifItHolds: content) != nil {
            return
        }
        history.record(content, sourceApp: copy.sourceApp, at: copy.date)
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
}

// MARK: - File thumbnails

extension ClipboardMonitor {
    /// Makes thumbnails of the copied photos and videos off the main actor, then records the files. Like an image,
    /// nothing is current meanwhile. Files still on the pasteboard at launch that are the newest entry already are
    /// not read again: the entry keeps what it has.
    private func storeFileThumbnails(_ files: [FileReference], copy: Copy) {
        guard let fileThumbnailIngestor else {
            return
        }
        if copy.isFirstRead, history.markNewestCurrent(ifItHolds: .files(files)) != nil {
            return
        }
        history.markCurrentSkipped()
        pendingIngestion = Task { [weak self] in
            let ingested = await fileThumbnailIngestor.ingest(files)
            guard let self else {
                fileThumbnailIngestor.discard(ingested)
                return
            }
            self.pendingIngestion = nil
            self.recordFiles(ingested, ingestor: fileThumbnailIngestor, copy: copy)
        }
    }

    private func recordFiles(_ files: [FileReference], ingestor: FileThumbnailIngestor, copy: Copy) {
        // This app wrote to the pasteboard meanwhile (an entry was copied back), so the files are no longer there
        // and the entry the user picked must stay on top.
        guard lastChangeCount == copy.changeCount else {
            AppLogger.clipboard.debug(
                "The pasteboard changed while file thumbnails were made; the files are not recorded")
            ingestor.discard(files)
            return
        }
        // The store deletes the thumbnails it does not keep, such as those of files it already has thumbnails for.
        history.record(.files(files), sourceApp: copy.sourceApp, at: copy.date)
    }
}
