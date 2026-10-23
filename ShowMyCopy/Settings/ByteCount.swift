import Foundation

/// Formats sizes for Settings, in the user's locale.
enum ByteCount {
    /// Content and limits, in decimal units as Finder shows file sizes: 1 MB is 1,000,000 bytes.
    static func fileSize(_ bytes: Int, locale: Locale = .current) -> String {
        Int64(max(bytes, 0)).formatted(.byteCount(style: .file).locale(locale))
    }

    /// App memory, in binary units as Activity Monitor shows it: 1 MB is 1,048,576 bytes.
    static func memorySize(_ bytes: UInt64, locale: Locale = .current) -> String {
        Int64(clamping: bytes).formatted(.byteCount(style: .memory).locale(locale))
    }
}
