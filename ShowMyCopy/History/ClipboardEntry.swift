import Foundation

struct ClipboardEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    var date: Date
    var sourceApp: SourceApp?
}

struct SourceApp: Equatable, Sendable {
    let bundleIdentifier: String?
    let name: String?
}
