/// Reads how much memory the app uses. The real reader asks the kernel and exists only on macOS, so Settings
/// take this protocol and tests pass a fake.
protocol MemoryUsageReading: Sendable {
    /// The app's memory footprint in bytes, the number Activity Monitor shows as Memory, or nil when the system
    /// does not report it.
    func residentBytes() -> UInt64?
}
