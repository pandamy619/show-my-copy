import AppKit

@MainActor
protocol PasteboardReading {
    var changeCount: Int { get }
    var types: [NSPasteboard.PasteboardType] { get }
    func string() -> String?
}

/// The parts of `NSPasteboard` the app uses. Tests replace it to check what is written.
@MainActor
protocol PasteboardBackend: AnyObject {
    var changeCount: Int { get }
    var types: [NSPasteboard.PasteboardType]? { get }
    func string(forType dataType: NSPasteboard.PasteboardType) -> String?
    func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
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
}

extension SystemPasteboard: PasteboardWriting {
    @discardableResult
    func write(_ text: String, concealed: Bool) -> Int? {
        // `.currentHostOnly` keeps an entry the user picked off Universal Clipboard, so history from this Mac is
        // not sent to the user's other devices again. For a password it also keeps it off the user's other devices.
        //
        // The change count increases when an app takes ownership of the pasteboard (`clearContents` or
        // `prepareForNewContents`), not when it adds data to contents it owns. So the count returned here is the
        // count of this app's item, and it stays the same while the text and markers are added.
        let changeCount = pasteboard.prepareForNewContents(with: .currentHostOnly)
        // The concealed marker goes before the text, so a clipboard manager that reads the item as soon as the text
        // appears already sees it. Without the marker it would keep the password, so do not write the text then.
        if concealed {
            guard pasteboard.setString("", forType: NSPasteboard.PasteboardType(PasteboardMarker.concealed)) else {
                return nil
            }
        }
        guard pasteboard.setString(text, forType: .string) else {
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
}
