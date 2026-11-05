import AppKit
import SwiftUI

/// Lets the row of `entry` be dragged into another app, unless it is a password's (`EntryDrag.canDrag`). A row that
/// can be dragged takes its clicks from `RowDragSource` (`onClick`); a password's row keeps its button's clicks.
struct RowDragModifier: ViewModifier {
    let entry: ClipboardEntry
    let model: HistoryWindowModel
    let onDrag: @MainActor (RowDragEvent) -> Void
    let onClick: @MainActor (_ isAlternate: Bool) -> Void

    func body(content: Content) -> some View {
        let canReadImages = model.imageBlobs != nil
        content
            .overlay {
                if EntryDrag.canDrag(entry, canReadImages: canReadImages) {
                    RowDragSource(
                        makeDrag: {
                            EntryDrag(
                                entry: entry, canReadImages: canReadImages,
                                imageTitle: { day, time in String(localized: "Image \(day) at \(time)") })
                        },
                        blobs: model.imageBlobs, onClick: onClick, onDrag: onDrag
                    )
                    .accessibilityHidden(true)
                }
            }
    }
}

/// Drags a history row's entry into another app, and passes the row's clicks on. `EntryDrag` decides what the drag
/// hands over; `PanelDragState` what the panel does meanwhile. This only starts the AppKit dragging session.
///
/// An AppKit dragging session and not SwiftUI's `onDrag` or `draggable`: on macOS 15 SwiftUI drags one item only,
/// so not all the files of an entry, gives other apps a copy of a file in its own cache instead of the file's URL,
/// and does not tell when the drag ends or whether it was dropped, which the panel needs to stay open and close.
/// The session puts the entry on the drag pasteboard only, never on the clipboard.
///
/// Over the row, it takes the left mouse button: a press that does not move is a click (`onClick`, with whether ⌥
/// was held), one that moves `EntryDrag.minimumDistance` starts the drag. A right click or ⌃-click and scroll events
/// go to the row underneath, so its context menu and swipe work as before. Not used for a password's row, which
/// cannot be dragged and keeps its own button's clicks.
struct RowDragSource: NSViewRepresentable {
    /// Called when the drag starts, so a long text is read into the drag only then.
    let makeDrag: @MainActor () -> EntryDrag?
    /// Where a dragged image is read from, when the app it is dropped on asks for it.
    let blobs: (any BlobStore)?
    let onClick: @MainActor (_ isAlternate: Bool) -> Void
    let onDrag: @MainActor (RowDragEvent) -> Void

    func makeNSView(context: Context) -> RowDragSourceView {
        let view = RowDragSourceView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: RowDragSourceView, context: Context) {
        view.makeDrag = makeDrag
        view.blobs = blobs
        view.onClick = onClick
        view.onDrag = onDrag
    }
}

final class RowDragSourceView: NSView, NSDraggingSource {
    var makeDrag: (@MainActor () -> EntryDrag?)?
    var blobs: (any BlobStore)?
    var onClick: (@MainActor (_ isAlternate: Bool) -> Void)?
    var onDrag: (@MainActor (RowDragEvent) -> Void)?

    /// The press that may become a click or a drag, until the button goes up or the drag starts.
    private var press: NSEvent?

    /// Only the left mouse button without ⌃ finds this view; everything else goes to the row underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApplication.shared.currentEvent, Self.takes(event) else {
            return nil
        }
        return super.hitTest(point)
    }

    private static func takes(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            return !event.modifierFlags.contains(.control)
        default:
            return false
        }
    }

    /// The panel is key but the app is never active: the first click must count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    /// The panel moves by its background; a row does not move it.
    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func mouseDown(with event: NSEvent) {
        press = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press, EntryDrag.isDrag(from: press.locationInWindow, to: event.locationInWindow) else {
            return
        }
        self.press = nil
        guard let drag = makeDrag?() else {
            return
        }
        let location = convert(press.locationInWindow, from: nil)
        let items = drag.items.compactMap { draggingItem(for: $0, at: location) }
        guard !items.isEmpty else {
            return
        }
        let session = beginDraggingSession(with: items, event: press, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        guard press != nil else {
            return
        }
        press = nil
        onClick?(event.modifierFlags.contains(.option))
    }

    private func draggingItem(for item: EntryDrag.Item, at location: NSPoint) -> NSDraggingItem? {
        let writer: any NSPasteboardWriting
        let symbol: String
        switch item {
        case .data(let representations):
            let pasteboardItem = NSPasteboardItem()
            for representation in representations {
                pasteboardItem.setData(
                    representation.data, forType: NSPasteboard.PasteboardType(representation.typeIdentifier))
            }
            writer = pasteboardItem
            symbol = "doc.plaintext"
        case .file(let url):
            writer = url as NSURL
            symbol = "doc"
        case .image(let image):
            guard let blobs else {
                return nil
            }
            let promise = ImageFilePromise(image: image, blobs: blobs)
            let provider = NSFilePromiseProvider(fileType: image.typeIdentifier, delegate: promise)
            // The provider keeps its delegate weakly: this keeps the promise until the image is written.
            provider.userInfo = promise
            writer = provider
            symbol = "photo"
        }
        let draggingItem = NSDraggingItem(pasteboardWriter: writer)
        let size = NSSize(width: 32, height: 32)
        let frame = NSRect(origin: NSPoint(x: location.x - size.width / 2, y: location.y - size.height / 2), size: size)
        draggingItem.setDraggingFrame(frame, contents: NSImage(systemSymbolName: symbol, accessibilityDescription: nil))
        return draggingItem
    }

    // MARK: - NSDraggingSource

    /// Copy into other apps, as pasting does; nothing inside this app, so a row dropped on the panel is cancelled.
    nonisolated func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    /// ⌥ or ⌘ do not turn the copy into a move or a link.
    nonisolated func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        MainActor.assumeIsolated {
            onDrag?(.began)
        }
    }

    nonisolated func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        let dropped = !operation.isEmpty
        MainActor.assumeIsolated {
            onDrag?(.ended(dropped: dropped))
        }
    }
}

/// A dragged image as a file promise: the app it is dropped on, such as Finder, Mail or Notes, names the place, and
/// only then is the image read from the blob store and written there, on the promise's own queue, never on the main
/// actor. The file gets `EntryDrag.PromisedImage.fileName`. Nothing is read when the drag starts.
///
/// Not on the main actor: AppKit calls it on `queue`. It only holds values set at creation.
nonisolated private final class ImageFilePromise: NSObject, NSFilePromiseProviderDelegate {
    private let image: EntryDrag.PromisedImage
    private let blobs: any BlobStore
    private let queue: OperationQueue

    init(image: EntryDrag.PromisedImage, blobs: any BlobStore) {
        self.image = image
        self.blobs = blobs
        queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        super.init()
    }

    nonisolated func filePromiseProvider(
        _ provider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        image.fileName
    }

    nonisolated func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue {
        queue
    }

    nonisolated func filePromiseProvider(
        _ provider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        do {
            let data = try blobs.read(image.blobID)
            try data.write(to: url)
            completionHandler(nil)
        } catch {
            AppLogger.clipboard.error("Could not write a dragged image for the app it was dropped on")
            completionHandler(error)
        }
    }
}
