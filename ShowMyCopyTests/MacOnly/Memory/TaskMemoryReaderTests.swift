import Testing

@testable import ShowMyCopy

struct TaskMemoryReaderTests {
    @Test func reportsAPlausibleFootprint() throws {
        let bytes = try #require(TaskMemoryReader().residentBytes())
        // A running Swift process with the test host loaded takes more than 1 MB and far less than 64 GB.
        #expect(bytes > 1_000_000)
        #expect(bytes < 64_000_000_000)
    }

    @Test func growsWhenTheProcessTouchesMoreMemory() throws {
        let reader = TaskMemoryReader()
        let before = try #require(reader.residentBytes())
        // 64 MB written to, so the pages count toward the footprint.
        var block = [UInt8](repeating: 1, count: 64_000_000)
        block[block.count - 1] = 2
        let after = try #require(reader.residentBytes())
        #expect(block.last == 2)
        #expect(after > before + 32_000_000)
    }
}
