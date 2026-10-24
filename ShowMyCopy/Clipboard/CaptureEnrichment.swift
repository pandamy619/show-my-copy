import Foundation

/// When and how a copy was made, for recording it.
struct CopyEvent: Sendable {
    let sourceApp: SourceApp?
    let date: Date
    /// The first read after launch: the item may be the newest entry, still on the pasteboard.
    let isFirstRead: Bool
}

/// Records copied images and files at once and fills in what takes long afterwards, off the main actor: an image's
/// data, size and thumbnail, and the thumbnails of copied photos and videos.
///
/// Both go the same way: the copy is recorded now, the slow work runs in the background, and its result is handed to
/// the entry, which keeps its place and current state. `ClipboardMonitor` goes on reading the pasteboard meanwhile, so
/// no copy is missed while an image is saved. The work for one copy runs after that of the copy before, so QuickLook
/// and ImageIO are never asked for many copies at once and results arrive in the order of the copies.
///
/// The work writes its blobs through a reservation of `blobs` (see `InFlightBlobStore`), so Clear History, the limits
/// and the launch sweep leave them alone until the result is handed on. Then the reservation is released and what no
/// entry took is deleted: a result for an entry that is gone leaves nothing behind.
@MainActor
final class CaptureEnrichment {
    private let history: any HistoryStore
    private let blobs: InFlightBlobStore
    private let images: ImageIngestor?
    private let fileThumbnails: FileThumbnailIngestor?
    /// The work for the copy recorded last, which runs after that of the copies before it, or nil when none runs.
    private var last: Task<Void, Never>?
    private var copiesInFlight = 0

    /// Without `images`, images are not read; without `fileThumbnails`, files keep their icons.
    init(
        history: any HistoryStore,
        blobs: InFlightBlobStore,
        images: ImageIngestor?,
        fileThumbnails: FileThumbnailIngestor?
    ) {
        self.history = history
        self.blobs = blobs
        self.images = images
        self.fileThumbnails = fileThumbnails
    }

    var readsImages: Bool {
        images != nil
    }

    var makesFileThumbnails: Bool {
        fileThumbnails != nil
    }

    /// Whether work for a recorded copy has not been handed to the history yet.
    var isEnriching: Bool {
        copiesInFlight > 0
    }

    /// Records `image` at once, as an image whose data is not saved yet (`ImageReference.unsaved`), current and on
    /// top, and saves it in the background. Its bytes stay readable from `blobs` meanwhile, so it can be copied back
    /// or previewed. Data that turns out not to be an image, or cannot be saved, takes its entry away again.
    func record(_ image: CapturedImage, as copy: CopyEvent) {
        guard let images else {
            return
        }
        let reservation = blobs.reservation()
        let blobID = reservation.newID()
        reservation.keepUnwritten(image.data, for: blobID)
        let unsaved = ImageReference.unsaved(
            blobID: blobID, typeIdentifier: image.typeIdentifier, byteSize: image.data.count)
        history.record(.image(unsaved), sourceApp: copy.sourceApp, at: copy.date)
        // Images already in the history, so copying one again writes nothing. Their blobs are held, so the one it
        // repeats keeps its data even if its entry is removed meanwhile.
        let known = Dictionary(
            history.entries.compactMap { entry in
                entry.content.image.flatMap { $0.isSaved ? ($0.contentHash, $0) : nil }
            },
            uniquingKeysWith: { first, _ in first })
        reservation.hold(known.values.flatMap(\.blobIDs))
        let history = history
        enqueue(reservation) { () -> Result<ImageReference, ImageIngestError> in
            do throws(ImageIngestError) {
                return .success(try await images.ingest(image, as: blobID, known: known, reservation: reservation))
            } catch {
                return .failure(error)
            }
        } handOn: { result in
            switch result {
            case .success(let saved):
                history.completeImage(unsaved, with: saved, keepsEarlierCopy: copy.isFirstRead)
            case .failure(let error):
                if error == .storageFailed {
                    AppLogger.clipboard.error("Could not save a copied image; it is removed from the history")
                }
                if let entry = history.entries.first(where: { $0.content.image == unsaved }) {
                    history.remove(id: entry.id)
                }
            }
        }
    }

    /// Records copied files at once, then makes thumbnails of the photos and videos among them in the background and
    /// adds them to the entry. Files still on the pasteboard at launch that are the newest entry already are not read
    /// again: the entry keeps what it has.
    func record(_ files: [FileReference], as copy: CopyEvent) {
        if copy.isFirstRead, history.markNewestCurrent(ifItHolds: .files(files)) != nil {
            return
        }
        let id = history.record(.files(files), sourceApp: copy.sourceApp, at: copy.date)
        // The entry's own files: copied again, they may have thumbnails already, which are not made again.
        guard let fileThumbnails,
            case .files(let recorded)? = history.entries.first(where: { $0.id == id })?.content
        else {
            return
        }
        let reservation = blobs.reservation()
        let history = history
        enqueue(reservation) {
            await fileThumbnails.ingest(recorded, reservation: reservation)
        } handOn: { made in
            // The store takes what the entry lacks, also when the entry is gone; the rest is deleted.
            history.addThumbnails(made, toEntry: id)
        }
    }

    /// Waits until the work for every copy recorded so far is handed to the history.
    func drain() async {
        while let last {
            await last.value
        }
    }

    /// The one way background work runs: after the work for the copy before, off the main actor, then its result is
    /// handed on here, the reservation released and what no entry took deleted.
    private func enqueue<Value: Sendable>(
        _ reservation: BlobReservation,
        work: @escaping @Sendable () async -> Value,
        handOn: @escaping @MainActor (Value) -> Void
    ) {
        let previous = last
        let blobs = blobs
        copiesInFlight += 1
        last = Task { [weak self] in
            await previous?.value
            let value = await work()
            guard let self else {
                Self.delete(reservation.release(), from: blobs)
                return
            }
            handOn(value)
            self.finish(reservation)
        }
    }

    private func finish(_ reservation: BlobReservation) {
        copiesInFlight -= 1
        if copiesInFlight == 0 {
            last = nil
        }
        let used = Set(history.entries.flatMap(\.content.blobIDs))
        Self.delete(reservation.release().filter { !used.contains($0) }, from: blobs)
    }

    private nonisolated static func delete(_ ids: [BlobID], from blobs: InFlightBlobStore) {
        guard !ids.isEmpty else {
            return
        }
        do {
            try blobs.delete(ids)
        } catch {
            AppLogger.history.error("Could not delete image data no entry uses; it goes at the next launch")
        }
    }
}
