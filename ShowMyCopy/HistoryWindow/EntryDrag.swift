import Foundation

/// What a history row hands over when the user drags it into another app: the same as copying it back would put on
/// the clipboard, but on the drag pasteboard only, so the clipboard and the history stay as they are. The view
/// (`RowDragSource.swift`) turns each item into one dragged item.
///
/// A password is never dragged: a concealed row offers no drag, and nothing of it is put on the drag pasteboard.
struct EntryDrag: Equatable, Sendable {
    /// One dragged item.
    enum Item: Equatable, Sendable {
        /// Data the entry holds in memory already, under each type, the richest first, so the app it is dropped on
        /// takes the best one it reads.
        case data([Representation])
        /// A copied file or folder by its URL, as Finder puts it on the pasteboard. Never its contents.
        case file(URL)
        /// An image, promised as a file and read from the blob store only when the app it is dropped on asks for it.
        case image(PromisedImage)
    }

    struct Representation: Equatable, Sendable {
        /// A Uniform Type Identifier, which is also the pasteboard type.
        let typeIdentifier: String
        let data: Data
    }

    /// The image of an entry, as a file the app it is dropped on gets.
    struct PromisedImage: Equatable, Sendable {
        let blobID: BlobID
        /// The format of the data, one of `ImageReference.supportedTypes`.
        let typeIdentifier: String
        /// Such as "Image 2026-11-05 at 16.10.png": a name Finder gives the file.
        let fileName: String
    }

    static let plainTextType = "public.utf8-plain-text"
    static let rtfType = "public.rtf"

    /// How far the mouse moves with its button down before a press on a row becomes a drag instead of a click.
    static let minimumDistance: CGFloat = 4

    let items: [Item]

    /// Whether the row of `entry` can be dragged at all, cheap enough to ask for every row shown. A password cannot,
    /// and neither can an image without a blob store to read it from (`canReadImages`) or an entry without files.
    static func canDrag(_ entry: ClipboardEntry, canReadImages: Bool) -> Bool {
        guard !entry.isConcealed else {
            return false
        }
        switch entry.content {
        case .text, .richText:
            return true
        case .image:
            return canReadImages
        case .files(let files):
            return !files.isEmpty
        }
    }

    /// What dragging `entry` hands over, or nil when it cannot be dragged (`canDrag`). Text is plain text; styled
    /// text is its RTF and its plain text; an image is a file in its own format named by `imageTitle` from the day
    /// and time it was copied in `timeZone` ("2026-11-05", "16.10"); files are their URLs, one item each.
    init?(
        entry: ClipboardEntry,
        canReadImages: Bool,
        imageTitle: (_ day: String, _ time: String) -> String,
        timeZone: TimeZone = .current
    ) {
        guard Self.canDrag(entry, canReadImages: canReadImages) else {
            return nil
        }
        switch entry.content {
        case .text(let text):
            items = [.data([Representation(typeIdentifier: Self.plainTextType, data: Data(text.utf8))])]
        case .richText(let rtf, let plain):
            items = [
                .data([
                    Representation(typeIdentifier: Self.rtfType, data: rtf),
                    Representation(typeIdentifier: Self.plainTextType, data: Data(plain.utf8)),
                ])
            ]
        case .image(let image):
            let stamp = Self.dayAndTime(of: entry.date, in: timeZone)
            let name = Self.fileName(imageTitle(stamp.day, stamp.time), typeIdentifier: image.typeIdentifier)
            items = [.image(PromisedImage(blobID: image.blobID, typeIdentifier: image.typeIdentifier, fileName: name))]
        case .files(let files):
            items = files.map { .file($0.url) }
        }
    }

    /// Whether the mouse moved from `start` to `location` far enough for a drag.
    static func isDrag(from start: CGPoint, to location: CGPoint) -> Bool {
        let deltaX = location.x - start.x
        let deltaY = location.y - start.y
        return (deltaX * deltaX + deltaY * deltaY).squareRoot() >= minimumDistance
    }

    /// The day as "2026-11-05" and the time as "16.10", as macOS names screenshots. A dot instead of a colon, which
    /// Finder shows as a slash.
    static func dayAndTime(of date: Date, in timeZone: TimeZone) -> (day: String, time: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let time = String(format: "%02d.%02d", parts.hour ?? 0, parts.minute ?? 0)
        return (day, time)
    }

    /// `title` with the extension of the image format, and with "/" and ":", which cannot be in a file name, as
    /// "-". An unknown format gets no extension.
    static func fileName(_ title: String, typeIdentifier: String) -> String {
        let safe = String(title.map { $0 == "/" || $0 == ":" ? "-" : $0 })
        guard let fileExtension = fileExtensions[typeIdentifier] else {
            return safe
        }
        return safe + "." + fileExtension
    }

    /// The extension macOS gives each image format the history keeps (`ImageReference.supportedTypes`).
    private static let fileExtensions = [
        "public.png": "png",
        "public.jpeg": "jpeg",
        "public.heic": "heic",
        "public.tiff": "tiff",
    ]
}
