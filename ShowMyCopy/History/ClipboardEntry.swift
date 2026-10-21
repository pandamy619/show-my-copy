import Foundation

struct ClipboardEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    var date: Date
    var sourceApp: SourceApp?
    /// A password: shown masked, left out of text search and removed at `expiresAt`.
    var isConcealed = false
    /// When a concealed entry is removed from the history. Nil for plain entries.
    var expiresAt: Date?
}

struct SourceApp: Equatable, Sendable {
    let bundleIdentifier: String?
    let name: String?
}
