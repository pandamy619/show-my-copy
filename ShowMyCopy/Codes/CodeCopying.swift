import Foundation

/// Puts an account's code on the pasteboard when the user picks it in the history window. `CodeCopier` is the app's
/// implementation; the window only needs to know whether the copy worked and which pasteboard change it made.
@MainActor
protocol CodeCopying: AnyObject {
    /// Returns the pasteboard's change count after the write, or nil when the code did not end up on the pasteboard.
    @discardableResult
    func copy(_ account: CodeAccount) -> Int?
}
