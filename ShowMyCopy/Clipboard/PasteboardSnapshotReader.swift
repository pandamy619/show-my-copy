import AppKit

/// What the current pasteboard item turned out to be.
enum CapturedItem: Equatable, Sendable {
    /// Content to record. `isSecret`: a password, by its marker or because a password manager copied it.
    case content(ClipboardContent, isSecret: Bool)
    /// Not recorded.
    case skipped(SkipReason)
    /// Nothing on the pasteboard: an app, usually a password manager, emptied it.
    case cleared

    enum SkipReason: Equatable, Sendable {
        /// Marked as transient or auto-generated: never kept.
        case marked
        /// A password while passwords are not saved. Its contents were not read.
        case secret
        /// No content reader found anything it records, for example in an image.
        case unsupported
        /// Larger than the size limit of the reader that found it.
        case tooLarge
    }
}

/// Reads the current pasteboard item for `ClipboardMonitor`.
///
/// It looks at the item's types and markers first and reads data only when the item may be recorded, so the text
/// of a password is not read while passwords are not saved. Each kind of content has its own `PasteboardContentReader`
/// with its own size limit, which it checks before it builds anything from the data.
///
/// Reading happens on the main actor: `NSPasteboard` is not `Sendable`, and its contents can change between calls,
/// which the monitor detects with `changeCount`. So readers only check sizes and copy the bytes out. Later work on
/// the content belongs in an ingestor that will sit between this reader and the history: it gets the `Sendable`
/// `CapturedItem` and, off the main actor, hashes the content, writes image and file data to disk and makes
/// thumbnails, then hands the finished entry to the history store on the main actor. Keep that work out of the
/// readers, or large copies will block the UI.
@MainActor
struct PasteboardSnapshotReader {
    private let pasteboard: any PasteboardReading
    /// Tried in order; the first that finds content wins. Readers for images, files or rich text go before the
    /// text reader, because such items usually carry a plain-text form too.
    private let contentReaders: [any PasteboardContentReader]

    init(pasteboard: any PasteboardReading, contentReaders: [any PasteboardContentReader] = [TextContentReader()]) {
        self.pasteboard = pasteboard
        self.contentReaders = contentReaders
    }

    /// Reads the current item. `fromPasswordManager`: a password manager is in front, so the item is a password
    /// even without a marker. The contents of a password are read only when `savesPasswords` is true.
    func read(fromPasswordManager: Bool, savesPasswords: Bool) -> CapturedItem {
        let markers = currentMarkers()
        if markers.contentTypes.isEmpty {
            return .cleared
        }
        var isSecret = fromPasswordManager || markers.isSecret
        if let reason = skipReason(markers, isSecret: isSecret, savesPasswords: savesPasswords) {
            return .skipped(reason)
        }
        let found = readContent()
        // An app can add a marker after the data without a new change count, so look at the markers again.
        let markersAfterRead = currentMarkers()
        isSecret = isSecret || markersAfterRead.isSecret
        if let reason = skipReason(markersAfterRead, isSecret: isSecret, savesPasswords: savesPasswords) {
            return .skipped(reason)
        }
        switch found {
        case .content(let content):
            return .content(content, isSecret: isSecret)
        case .tooLarge(let limit):
            AppLogger.clipboard.info("Skipped an item larger than \(limit, privacy: .public) bytes")
            return .skipped(.tooLarge)
        case .nothing:
            // Empty text, or a text type without text, is what an app leaves when it empties the clipboard.
            return markersAfterRead.contentTypes.isSubset(of: Self.textTypes) ? .cleared : .skipped(.unsupported)
        }
    }

    private func readContent() -> ContentReading {
        for reader in contentReaders {
            let found = reader.read(from: pasteboard)
            if found != .nothing {
                return found
            }
        }
        return .nothing
    }

    private func skipReason(_ markers: Markers, isSecret: Bool, savesPasswords: Bool) -> CapturedItem.SkipReason? {
        if markers.isAlwaysSkipped {
            AppLogger.clipboard.debug("Skipped an item marked as transient or auto-generated")
            return .marked
        }
        if isSecret, !savesPasswords {
            AppLogger.clipboard.debug("Skipped a secret item")
            return .secret
        }
        return nil
    }

    /// Types that hold plain text. An item with only these types and no text is an emptied clipboard.
    private static let textTypes: Set<NSPasteboard.PasteboardType> = [
        .string, NSPasteboard.PasteboardType("NSStringPboardType"),
    ]

    private struct Markers {
        var isSecret: Bool
        var isAlwaysSkipped: Bool
        /// The types that hold data, without the nspasteboard.org markers.
        var contentTypes: Set<NSPasteboard.PasteboardType>
    }

    private func currentMarkers() -> Markers {
        let types = Set(pasteboard.types)
        let names = Set(types.map(\.rawValue))
        let markerNames = PasteboardMarker.secret.union(PasteboardMarker.alwaysSkipped).union([PasteboardMarker.source])
        return Markers(
            isSecret: !names.isDisjoint(with: PasteboardMarker.secret),
            isAlwaysSkipped: !names.isDisjoint(with: PasteboardMarker.alwaysSkipped),
            contentTypes: types.filter { !markerNames.contains($0.rawValue) }
        )
    }
}

/// What a content reader found on the current item.
enum ContentReading: Equatable, Sendable {
    case content(ClipboardContent)
    /// Nothing of the reader's kind, or only an empty value.
    case nothing
    /// Content larger than `limit` bytes. It was not decoded.
    case tooLarge(limit: Int)
}

/// Reads one kind of content, such as plain text, from the current pasteboard item, within its own size limit.
@MainActor
protocol PasteboardContentReader {
    func read(from pasteboard: any PasteboardReading) -> ContentReading
}

/// Reads plain text.
struct TextContentReader: PasteboardContentReader {
    nonisolated static let defaultMaximumBytes = 1_048_576

    /// The largest text kept, in UTF-8 bytes.
    let maximumBytes: Int

    init(maximumBytes: Int = TextContentReader.defaultMaximumBytes) {
        self.maximumBytes = maximumBytes
    }

    /// Reads the UTF-8 data first and checks its size, so text over the limit is never decoded into a `String`.
    /// `string()` is only a fallback for an item whose text is not available as UTF-8 data.
    func read(from pasteboard: any PasteboardReading) -> ContentReading {
        var text: String?
        if let data = pasteboard.data(forType: .string) {
            guard data.count <= maximumBytes else {
                return .tooLarge(limit: maximumBytes)
            }
            text = String(data: data, encoding: .utf8)
        }
        if text == nil {
            text = pasteboard.string()
        }
        guard let text, !text.isEmpty else {
            return .nothing
        }
        // A string from the fallback was not checked yet.
        guard text.utf8.count <= maximumBytes else {
            return .tooLarge(limit: maximumBytes)
        }
        return .content(.text(text))
    }
}
