import AppKit

@testable import ShowMyCopy

@MainActor
final class FakePasteboard: PasteboardReading, PasteboardWriting {
    var changeCount = 0
    var types: [NSPasteboard.PasteboardType] = []
    var text: String?
    private(set) var writtenTexts: [String] = []

    func string() -> String? {
        text
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

    func write(_ text: String) -> Int {
        writtenTexts.append(text)
        copy(text)
        return changeCount
    }
}
