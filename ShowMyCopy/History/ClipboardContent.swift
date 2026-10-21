import Foundation

/// What was copied, independent of where the history keeps it.
///
/// Only plain text is recorded today. Later versions add cases here, for example `richText` (RTF or HTML data with
/// its plain text), `image` (a reference to stored image data with its size) and `files` (file URLs). Switch over
/// this type without a `default` case, so the compiler lists every place that has to handle a new kind.
enum ClipboardContent: Equatable, Sendable {
    case text(String)

    /// The kind of content, for filters, icons and storage. One case per case of `ClipboardContent`.
    enum Kind: String, CaseIterable, Sendable {
        case text
    }

    var kind: Kind {
        switch self {
        case .text:
            .text
        }
    }

    /// The plain text, or nil for content that has none.
    var text: String? {
        switch self {
        case .text(let text):
            text
        }
    }

    /// The size of the content's data in bytes: the UTF-8 length for text. Used for size limits and statistics.
    var byteSize: Int {
        switch self {
        case .text(let text):
            text.utf8.count
        }
    }

    /// The bytes the content hash is computed from: a tag for the kind, then the content's data.
    ///
    /// Text is normalized to NFC first, so text that Swift considers equal (such as "é" written as one or two
    /// scalars) gets the same hash, as it did when entries were compared by text. Hashes are kept with the history,
    /// so never change the encoding of an existing case: a new kind gets a new tag.
    var canonicalBytes: Data {
        switch self {
        case .text(let text):
            var data = Data([Self.textTag])
            data.append(contentsOf: text.precomposedStringWithCanonicalMapping.utf8)
            return data
        }
    }

    private static let textTag: UInt8 = 0x01
}
