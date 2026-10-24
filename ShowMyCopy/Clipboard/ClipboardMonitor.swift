import AppKit

/// Records new copies in the history.
///
/// `schedule` says when to look at the pasteboard; on each look the monitor compares `changeCount` and reads the
/// contents only when the count changed. It decides who copied and what the password settings allow;
/// `PasteboardSnapshotReader` decides what the item is. Expired passwords go on every look (`expiry`), and an
/// emptied clipboard may mark the entry copied just before as a password (`clearedClipboard`).
///
/// A copied image is stored by `imageIngestor` off the main actor before it is recorded. Until then the monitor reads
/// no further change, so copies are recorded in the order they were made. Copied files are recorded at once; the
/// thumbnails of photos and videos among them are made by `fileThumbnailIngestor` afterwards, one copy after another,
/// and added to their entries, so no copy is missed while they are made.
@MainActor
final class ClipboardMonitor: PasteboardChangeTracking {
    private let pasteboard: any PasteboardReading
    private let reader: PasteboardSnapshotReader
    private let history: any HistoryStore
    private let schedule: PollingSchedule
    private let expiry: PasswordExpiry
    private let clearedClipboard: ClearedClipboardCheck
    private let frontmostApp: @MainActor () -> SourceApp?
    private let now: @MainActor () -> Date
    private let passwordPolicy: @MainActor () -> PasswordPolicy
    /// Stores copied images. Without it images are not read.
    private let imageIngestor: ImageIngestor?
    /// Makes thumbnails of copied photo and video files. Without it files are recorded at once, with their icons.
    private let fileThumbnailIngestor: FileThumbnailIngestor?
    /// Storing the image read last, or nil.
    private var pendingIngestion: Task<Void, Never>?
    /// Making the thumbnails of the files recorded last, after those of earlier copies, or nil.
    private var pendingFileThumbnails: Task<Void, Never>?
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
        frontmostApp: @escaping @MainActor () -> SourceApp?,
        now: @escaping @MainActor () -> Date,
        passwordPolicy: @escaping @MainActor () -> PasswordPolicy,
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
        self.schedule = schedule
        self.expiry = expiry
        self.clearedClipboard = clearedClipboard
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

    /// Marks a pasteboard change made by this app as seen, so it is not recorded again as a copy
    /// from whichever app is in front.
    func acknowledge(changeCount: Int) {
        lastChangeCount = changeCount
    }

    /// Checks the pasteboard once. The first call records whatever is on the pasteboard at launch.
    func poll() {
        expiry.removeExpired()
        let date = now()
        guard pendingIngestion == nil else {
            // The next change is read once the image is recorded, so it ends up above the image.
            return
        }
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
        let copy = Copy(
            sourceApp: sourceApp, date: date, isFirstRead: lastChangeCount == nil, changeCount: changeCount)
        sourceOfNextChangeIsUnknown = false
        lastChangeCount = changeCount
        handle(item, copy: copy, policy: policy)
    }

    private func handle(_ item: CapturedItem, copy: Copy, policy: PasswordPolicy) {
        switch item {
        case .skipped:
            history.markCurrentSkipped()
        case .image(let image):
            storeImage(image, copy: copy)
        case .cleared:
            clearedClipboard.clipboardWasEmptied(changeCount: copy.changeCount, at: copy.date)
        case .content(.files(let files), isSecret: false) where fileThumbnailIngestor != nil:
            recordFiles(files, copy: copy)
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

    /// Waits until the image read last is stored and recorded and the thumbnails of the files recorded so far are
    /// added. For tests and for quitting cleanly.
    func finishStoringImages() async {
        await pendingIngestion?.value
        await pendingFileThumbnails?.value
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
}

// MARK: - File thumbnails

extension ClipboardMonitor {
    /// Records the copied files at once, then makes thumbnails of the photos and videos among them off the main
    /// actor and adds them to the entry, which keeps its place and current state. Files still on the pasteboard at
    /// launch that are the newest entry already are not read again: the entry keeps what it has.
    private func recordFiles(_ files: [FileReference], copy: Copy) {
        if copy.isFirstRead, history.markNewestCurrent(ifItHolds: .files(files)) != nil {
            return
        }
        let id = history.record(.files(files), sourceApp: copy.sourceApp, at: copy.date)
        // The entry's own files: copied again, they may have thumbnails already, which are not made again.
        guard let fileThumbnailIngestor,
            case .files(let recorded)? = history.entries.first(where: { $0.id == id })?.content
        else {
            return
        }
        let previous = pendingFileThumbnails
        pendingFileThumbnails = Task { [weak self] in
            // One copy after another, so QuickLook is never asked for many files at once.
            await previous?.value
            let made = await fileThumbnailIngestor.ingest(recorded)
            guard let self else {
                fileThumbnailIngestor.discard(made)
                return
            }
            // The store takes what the entry lacks and deletes the rest, also when the entry is gone.
            self.history.addThumbnails(made, toEntry: id)
        }
    }
}
