@testable import ShowMyCopy

/// Reports no memory reading, as when the system does not say.
struct NoMemoryUsage: MemoryUsageReading {
    func residentBytes() -> UInt64? { nil }
}
