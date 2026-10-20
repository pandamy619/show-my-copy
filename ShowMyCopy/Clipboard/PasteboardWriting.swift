import Foundation

@MainActor
protocol PasteboardWriting: AnyObject {
    /// Replaces the pasteboard contents with plain text and returns the pasteboard's new `changeCount`.
    @discardableResult
    func write(_ text: String) -> Int
}
