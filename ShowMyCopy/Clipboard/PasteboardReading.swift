import AppKit

@MainActor
protocol PasteboardReading {
    var changeCount: Int { get }
    var types: [NSPasteboard.PasteboardType] { get }
    func string() -> String?
    /// The current item's data for `dataType`, without converting it. For `.string` it is UTF-8 text, so its size
    /// can be checked before a `String` is made from it.
    func data(forType dataType: NSPasteboard.PasteboardType) -> Data?
    /// How many items the pasteboard holds. Copied files are one item each, so this counts them without reading.
    var itemCount: Int { get }
    /// The file URLs of all items, in order. Other URLs are left out.
    func fileURLs() -> [URL]
}

/// The parts of `NSPasteboard` the app uses. Tests replace it to check what is written.
@MainActor
protocol PasteboardBackend: AnyObject {
    var changeCount: Int { get }
    var types: [NSPasteboard.PasteboardType]? { get }
    func string(forType dataType: NSPasteboard.PasteboardType) -> String?
    func data(forType dataType: NSPasteboard.PasteboardType) -> Data?
    var pasteboardItems: [NSPasteboardItem]? { get }
    func readObjects(forClasses classArray: [AnyClass], options: [NSPasteboard.ReadingOptionKey: Any]?) -> [Any]?
    func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int
    func clearContents() -> Int
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
    func setData(_ data: Data?, forType dataType: NSPasteboard.PasteboardType) -> Bool
    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool
}

extension NSPasteboard: PasteboardBackend {}

@MainActor
final class SystemPasteboard: PasteboardReading {
    private let pasteboard: any PasteboardBackend
    private let bundleIdentifier: String?

    init(
        pasteboard: any PasteboardBackend = NSPasteboard.general,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) {
        self.pasteboard = pasteboard
        self.bundleIdentifier = bundleIdentifier
    }

    var changeCount: Int {
        pasteboard.changeCount
    }

    var types: [NSPasteboard.PasteboardType] {
        pasteboard.types ?? []
    }

    func string() -> String? {
        pasteboard.string(forType: .string)
    }

    func data(forType dataType: NSPasteboard.PasteboardType) -> Data? {
        pasteboard.data(forType: dataType)
    }

    var itemCount: Int {
        pasteboard.pasteboardItems?.count ?? 0
    }

    func fileURLs() -> [URL] {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (objects ?? []).compactMap { $0 as? URL }
    }
}

extension SystemPasteboard: PasteboardWriting {
    @discardableResult
    func write(_ payload: PasteboardPayload, concealed: Bool) -> Int? {
        // `.currentHostOnly` keeps an entry the user picked off Universal Clipboard, so history from this Mac is
        // not sent to the user's other devices again. For a password it also keeps it off the user's other devices.
        //
        // The change count increases when an app takes ownership of the pasteboard (`clearContents` or
        // `prepareForNewContents`), not when it adds data to contents it owns. So the count returned here is the
        // count of this app's item, and it stays the same while the text and markers are added.
        let changeCount = pasteboard.prepareForNewContents(with: .currentHostOnly)
        // The concealed marker goes before the content, so a clipboard manager that reads the item as soon as the
        // content appears already sees it. Without the marker it would keep the password, so do not write it then.
        if concealed {
            guard pasteboard.setString("", forType: NSPasteboard.PasteboardType(PasteboardMarker.concealed)) else {
                return nil
            }
        }
        guard writeContent(payload) else {
            return nil
        }
        if let bundleIdentifier {
            // Tells other clipboard tools which app wrote the item. Losing this marker is not worth failing for.
            _ = pasteboard.setString(bundleIdentifier, forType: NSPasteboard.PasteboardType(PasteboardMarker.source))
        }
        // If another app wrote after this app, its item is on the pasteboard now. Do not report that newer count
        // as this app's write, or the monitor would treat the other app's copy as already seen and lose it.
        guard pasteboard.changeCount == changeCount else {
            return nil
        }
        return changeCount
    }

    func clearContents(ifChangeCountIs changeCount: Int) -> Int? {
        // NSPasteboard has no way to clear only an item it still holds, so the check and the clear run back to back
        // on the main thread. Another app could still write between the two; the time for that is a few calls long.
        guard pasteboard.changeCount == changeCount else {
            return nil
        }
        return pasteboard.clearContents()
    }

    private func writeContent(_ payload: PasteboardPayload) -> Bool {
        switch payload {
        case .text(let text):
            return pasteboard.setString(text, forType: .string)
        case .richText(let rtf, let plain):
            return pasteboard.setData(rtf, forType: .rtf) && pasteboard.setString(plain, forType: .string)
        case .image(let data, let typeIdentifier):
            return pasteboard.setData(data, forType: NSPasteboard.PasteboardType(typeIdentifier))
        case .files(let urls):
            // One item per file, like Finder. The source marker then goes on the first item.
            return pasteboard.writeObjects(urls.map { $0 as NSURL })
        }
    }
}
