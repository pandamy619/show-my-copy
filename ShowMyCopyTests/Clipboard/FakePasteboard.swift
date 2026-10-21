import AppKit

@testable import ShowMyCopy

@MainActor
final class FakePasteboard: PasteboardReading, PasteboardWriting {
    var changeCount = 0
    var types: [NSPasteboard.PasteboardType] = []
    var text: String?
    private(set) var writtenTexts: [String] = []
    /// When true, `write` fails and leaves the pasteboard unchanged.
    var writeFails = false
    /// Runs once inside the next `string()` call, before the text is returned, to simulate another app
    /// writing to the pasteboard while the monitor reads it.
    var whileReadingString: (@MainActor (FakePasteboard) -> Void)?

    func string() -> String? {
        if let hook = whileReadingString {
            whileReadingString = nil
            hook(self)
        }
        return text
    }

    /// Adds a marker to the current item without a new change count, like an app that adds types after the text.
    func addMarker(_ marker: String) {
        types.append(NSPasteboard.PasteboardType(marker))
    }

    func copy(_ text: String, markers: [String] = []) {
        changeCount += 1
        self.text = text
        types = [.string] + markers.map { NSPasteboard.PasteboardType($0) }
    }

    func copyImage() {
        changeCount += 1
        text = nil
        types = [.png, .tiff]
    }

    func write(_ text: String) -> Int? {
        guard !writeFails else {
            return nil
        }
        writtenTexts.append(text)
        copy(text)
        return changeCount
    }
}
