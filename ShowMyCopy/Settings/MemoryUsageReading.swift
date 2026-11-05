/// Reads how much memory the app uses. The real reader (`TaskMemoryReader`) asks the kernel; Settings take this
/// protocol so tests can pass a fake.
protocol MemoryUsageReading: Sendable {
    /// The app's memory footprint in bytes, the number Activity Monitor shows as Memory, or nil when the system
    /// does not report it.
    func residentBytes() -> UInt64?
}
