import Foundation

@MainActor
protocol PasteboardWriting: AnyObject {
    /// Replaces the pasteboard contents with plain text. Returns the `changeCount` of the item this app wrote,
    /// or nil when the text is not on the pasteboard (the write failed or another app wrote right after it).
    @discardableResult
    func write(_ text: String) -> Int?
}
