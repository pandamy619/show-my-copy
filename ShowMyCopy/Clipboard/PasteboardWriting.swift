import Foundation

/// What this app puts on the pasteboard when an entry is copied back: the content as the app that pastes it
/// expects it.
enum PasteboardPayload: Equatable, Sendable {
    case text(String)
    /// RTF data with its plain text, so apps that paste plain text only still get the words.
    case richText(rtf: Data, plain: String)
    /// Image data in its original format, under its Uniform Type Identifier.
    case image(Data, typeIdentifier: String)
    /// File URLs, one pasteboard item each, as Finder writes them.
    case files([URL])
}

@MainActor
protocol PasteboardWriting: AnyObject {
    /// Replaces the pasteboard contents with `payload`. Returns the `changeCount` of the item this app wrote,
    /// or nil when the content is not on the pasteboard (the write failed or another app wrote right after it).
    ///
    /// A `concealed` write marks the item with `PasteboardMarker.concealed`, so other clipboard managers skip it.
    @discardableResult
    func write(_ payload: PasteboardPayload, concealed: Bool) -> Int?
}

extension PasteboardWriting {
    /// Replaces the pasteboard contents with plain text. See `write(_:concealed:)`.
    @discardableResult
    func write(_ text: String, concealed: Bool) -> Int? {
        write(.text(text), concealed: concealed)
    }

    @discardableResult
    func write(_ text: String) -> Int? {
        write(.text(text), concealed: false)
    }
}
