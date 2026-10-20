import Foundation
import os

enum AppLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.pandamy619.ShowMyCopy"

    /// Never log clipboard contents. Log only what kind of item was seen and why it was skipped.
    static let clipboard = Logger(subsystem: subsystem, category: "clipboard")
}
