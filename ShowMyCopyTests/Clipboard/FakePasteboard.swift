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
    /// The file URLs on the pasteboard, one per item, like `readObjects(forClasses: [NSURL.self])` returns them.
    var copiedFileURLs: [URL] = []
    /// How often the file URLs were read, to check that too many files are not read at all.
    private(set) var fileURLReadCount = 0
    /// The text of every plain-text write.
    private(set) var writtenTexts: [String] = []
    /// Every write, of any kind.
    private(set) var writtenPayloads: [PasteboardPayload] = []
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

    /// One item per file, otherwise one item while there is anything on the pasteboard.
    var itemCount: Int {
        max(copiedFileURLs.count, types.isEmpty ? 0 : 1)
    }

    func fileURLs() -> [URL] {
        fileURLReadCount += 1
        runReadHook()
        return copiedFileURLs
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
        copiedFileURLs = []
        self.text = text
        types = [.string] + markers.map { NSPasteboard.PasteboardType($0) }
    }

    /// Another app copies an item with the given data per type, for kinds other than plain text.
    func copy(_ contents: [NSPasteboard.PasteboardType: Data], markers: [String] = []) {
        changeCount += 1
        self.contents = contents
        convertedString = nil
        copiedFileURLs = []
        types = contents.keys.sorted { $0.rawValue < $1.rawValue } + markers.map { NSPasteboard.PasteboardType($0) }
    }

    /// Another app empties the pasteboard, like a password manager clearing a copied password.
    func clear() {
        changeCount += 1
        contents = [:]
        convertedString = nil
        copiedFileURLs = []
        types = []
    }

    /// The app that emptied the pasteboard writes text into it now, without a new change count, like an app that
    /// calls `clearContents()` and fills the item a moment later.
    func fillWithoutNewChangeCount(_ text: String) {
        contents = [:]
        copiedFileURLs = []
        self.text = text
        types = [.string]
    }

    func copyImage() {
        copy([.png: Data([0x89, 0x50, 0x4E, 0x47]), .tiff: Data([0x4D, 0x4D])])
    }

    /// Finder copies files: one file URL per item, the names as text and an icon.
    func copyFiles(_ urls: [URL], markers: [String] = []) {
        copy(
            [
                .fileURL: Data((urls.first?.absoluteString ?? "").utf8),
                .string: Data(urls.map(\.lastPathComponent).joined(separator: "\r").utf8),
                .tiff: Data([0x4D, 0x4D]),
            ], markers: markers)
        copiedFileURLs = urls
    }

    /// TextEdit copies styled text: RTF and its plain text.
    func copyRichText(_ plain: String, rtf: Data = Data(#"{\rtf1 styled}"#.utf8), markers: [String] = []) {
        copy([.rtf: rtf, .string: Data(plain.utf8)], markers: markers)
    }

    func write(_ payload: PasteboardPayload, concealed: Bool) -> Int? {
        guard !writeFails else {
            return nil
        }
        writtenPayloads.append(payload)
        writtenConcealed.append(concealed)
        let markers = concealed ? [PasteboardMarker.concealed] : []
        switch payload {
        case .text(let text):
            writtenTexts.append(text)
            copy(text, markers: markers)
        case .richText(let rtf, let plain):
            copyRichText(plain, rtf: rtf, markers: markers)
        case .image(let data, let typeIdentifier):
            copy([NSPasteboard.PasteboardType(typeIdentifier): data], markers: markers)
        case .files(let urls):
            copyFiles(urls, markers: markers)
        }
        return changeCount
    }
}
