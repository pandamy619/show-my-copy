import Foundation

@testable import ShowMyCopy

/// The name the in-memory store had before `HistoryStore`; the tests still use it.
typealias ClipboardHistory = InMemoryHistoryStore

extension InMemoryHistoryStore {
    nonisolated static let defaultLimit = RetentionPolicy.defaultEntryLimit
    nonisolated static let limitRange = RetentionPolicy.entryLimitRange

    /// A store that keeps at most `limit` entries.
    convenience init(limit: Int) {
        self.init(retention: RetentionPolicy(entryLimit: limit))
    }
}

extension HistoryStore {
    /// The most entries kept.
    var limit: Int {
        retention.entryLimit
    }

    /// Records copied text. See `record(_:sourceApp:at:concealed:expiresAt:)`.
    @discardableResult
    func record(
        text: String,
        sourceApp: SourceApp?,
        at date: Date,
        concealed: Bool = false,
        expiresAt: Date? = nil
    ) -> ClipboardEntry.ID {
        record(.text(text), sourceApp: sourceApp, at: date, concealed: concealed, expiresAt: expiresAt)
    }

    func setLimit(_ newLimit: Int) {
        setRetention(retention.withEntryLimit(newLimit))
    }
}

extension ClipboardEntry {
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
}
