import Foundation

/// One item in the clipboard history.
///
/// The content and what is derived from it (hash, size, preview) are fixed when the entry is made. A repeated copy
/// of the same content changes only the date, the source app and the concealed state.
struct ClipboardEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let content: ClipboardContent
    /// Identifies the content: entries with equal hashes hold the same content.
    let contentHash: ContentHash
    /// The size of the content in bytes, for size limits and statistics.
    let byteSize: Int
    /// Short, sanitized text for a history row, made once at capture so the list never walks large content.
    /// For a concealed entry it is shown only after the user reveals it.
    let previewText: String
    var date: Date
    var sourceApp: SourceApp? {
        didSet {
            sourceAppSearchKey = SearchKey.appName(of: sourceApp)
        }
    }
    /// A password: shown masked, left out of text search and removed at `expiresAt`.
    var isConcealed: Bool {
        didSet {
            if isConcealed != oldValue {
                searchKey = isConcealed ? nil : SearchKey.text(of: content)
            }
        }
    }
    /// The start of the text, folded for search when the entry is made, so typing a query does not fold every
    /// entry again. Nil for a concealed entry: search never looks inside a password.
    private(set) var searchKey: String?
    /// The source app's name, folded for search. A concealed entry is found only by this.
    private(set) var sourceAppSearchKey: String?
    /// When a concealed entry is removed from the history. Nil for plain entries.
    var expiresAt: Date?
    /// A pinned entry is never removed by the history limits. Nothing pins entries yet.
    var isPinned: Bool

    init(
        id: UUID = UUID(),
        content: ClipboardContent,
        contentHash: ContentHash,
        date: Date,
        sourceApp: SourceApp?,
        isConcealed: Bool = false,
        expiresAt: Date? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.content = content
        self.contentHash = contentHash
        self.byteSize = content.byteSize
        self.previewText = Self.preview(of: content)
        self.date = date
        self.sourceApp = sourceApp
        self.isConcealed = isConcealed
        self.expiresAt = expiresAt
        self.isPinned = isPinned
        self.searchKey = isConcealed ? nil : SearchKey.text(of: content)
        self.sourceAppSearchKey = SearchKey.appName(of: sourceApp)
    }

    /// Makes a text entry, hashing the text with `hasher`.
    init(
        id: UUID = UUID(),
        text: String,
        date: Date,
        sourceApp: SourceApp?,
        isConcealed: Bool = false,
        expiresAt: Date? = nil,
        hasher: any ContentHasher = SHA256ContentHasher()
    ) {
        let content = ClipboardContent.text(text)
        self.init(
            id: id,
            content: content,
            contentHash: hasher.hash(content),
            date: date,
            sourceApp: sourceApp,
            isConcealed: isConcealed,
            expiresAt: expiresAt
        )
    }

    var kind: ClipboardContent.Kind {
        content.kind
    }

    /// The plain text of the content, or nil for content without text. Rich text gives its plain text.
    var text: String? {
        content.text
    }

    private static func preview(of content: ClipboardContent) -> String {
        switch content {
        case .text(let text):
            EntryPreview.text(text)
        case .richText(_, let plain):
            EntryPreview.text(plain)
        case .image(let image):
            // Not localized: a format name and a pixel size read the same in every language.
            "\(image.formatName) \(image.pixelWidth) × \(image.pixelHeight)"
        case .files(let files):
            EntryPreview.text(files.map(\.name).joined(separator: "\n"))
        }
    }
}

struct SourceApp: Equatable, Sendable {
    let bundleIdentifier: String?
    let name: String?
}
