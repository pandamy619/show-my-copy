import AppKit

@testable import ShowMyCopy

@MainActor
final class FakePasteboard: PasteboardReading, PasteboardWriting {
    var changeCount = 0
    var types: [NSPasteboard.PasteboardType] = []
    /// The data of the current item per type, like `NSPasteboard.data(forType:)` returns it. Text is UTF-8 data
    /// under `.string`; other kinds (RTF, PNG, file URLs) can be put here under their own types.
    var contents: [NSPasteboard.PasteboardType: Data] = [:]
    /// What `string()` returns instead of decoding `contents[.string]`, like `NSPasteboard` converting text it
    /// holds in another form. Nil: `string()` decodes the UTF-8 data.
    var convertedString: String?
    private(set) var writtenTexts: [String] = []
    /// For each write, whether it was marked as concealed.
    private(set) var writtenConcealed: [Bool] = []
    /// How often the text was read, as a string or as data, to check that secrets are not read when they are not
    /// kept.
    private(set) var stringReadCount = 0
    /// How often `string()` was called, to check that text too large to keep is not turned into a string.
    private(set) var stringCallCount = 0
    /// How often data of any type was read.
    private(set) var dataReadCount = 0
    /// When true, `write` fails and leaves the pasteboard unchanged.
    var writeFails = false
    /// Runs once inside the next `string()` or `data(forType:)` call, before the contents are returned, to simulate
    /// another app writing to the pasteboard while the monitor reads it.
    var whileReadingString: (@MainActor (FakePasteboard) -> Void)?

    /// The text of the current item. Setting it replaces the UTF-8 data under `.string`, without a new change count.
    var text: String? {
        get {
            convertedString ?? contents[.string].flatMap { String(data: $0, encoding: .utf8) }
        }
        set {
            contents[.string] = newValue.map { Data($0.utf8) }
            convertedString = nil
        }
    }

    func string() -> String? {
        stringReadCount += 1
        stringCallCount += 1
        runReadHook()
        return text
    }

    func data(forType dataType: NSPasteboard.PasteboardType) -> Data? {
        dataReadCount += 1
        if dataType == .string {
            stringReadCount += 1
        }
        runReadHook()
        return contents[dataType]
    }

    private func runReadHook() {
        if let hook = whileReadingString {
            whileReadingString = nil
            hook(self)
        }
    }

    /// Adds a marker to the current item without a new change count, like an app that adds types after the text.
    func addMarker(_ marker: String) {
        types.append(NSPasteboard.PasteboardType(marker))
    }

    func copy(_ text: String, markers: [String] = []) {
        changeCount += 1
        contents = [:]
        self.text = text
        types = [.string] + markers.map { NSPasteboard.PasteboardType($0) }
    }

    /// Another app copies an item with the given data per type, for kinds other than plain text.
    func copy(_ contents: [NSPasteboard.PasteboardType: Data], markers: [String] = []) {
        changeCount += 1
        self.contents = contents
        convertedString = nil
        types = contents.keys.sorted { $0.rawValue < $1.rawValue } + markers.map { NSPasteboard.PasteboardType($0) }
    }

    /// Another app empties the pasteboard, like a password manager clearing a copied password.
    func clear() {
        changeCount += 1
        contents = [:]
        convertedString = nil
        types = []
    }

    func copyImage() {
        copy([.png: Data([0x89, 0x50, 0x4E, 0x47]), .tiff: Data([0x4D, 0x4D])])
    }

    func write(_ text: String, concealed: Bool) -> Int? {
        guard !writeFails else {
            return nil
        }
        writtenTexts.append(text)
        writtenConcealed.append(concealed)
        copy(text, markers: concealed ? [PasteboardMarker.concealed] : [])
        return changeCount
    }
}
