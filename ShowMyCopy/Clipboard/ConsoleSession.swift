import CoreGraphics

/// Reads the state of the user's login session from the window server, to check pause reasons that were set by
/// notifications.
enum ConsoleSession {
    /// Whether the screen is locked. When the state cannot be read it counts as unlocked, so a stale lock cannot
    /// stop recording for good.
    static func isScreenLocked() -> Bool {
        flag("CGSSessionScreenIsLocked") ?? false
    }

    /// Whether this session is the one on the screen, not one switched away from with fast user switching.
    /// When the state cannot be read it counts as active, for the same reason.
    static func isActive() -> Bool {
        // The value of `kCGSessionOnConsoleKey`, which is a `CFSTR` macro and not visible in Swift.
        flag("kCGSSessionOnConsoleKey") ?? true
    }

    private static func flag(_ key: String) -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return nil
        }
        return session[key] as? Bool
    }
}
