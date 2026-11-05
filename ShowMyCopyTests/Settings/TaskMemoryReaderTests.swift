import Testing

@testable import ShowMyCopy

struct TaskMemoryReaderTests {
    @Test func reportsAPlausibleFootprint() throws {
        let bytes = try #require(TaskMemoryReader().residentBytes())
        // A running Swift process with the test host loaded takes more than 1 MB and far less than 64 GB.
        #expect(bytes > 1_000_000)
        #expect(bytes < 64_000_000_000)
    }

    @Test func countsMemoryTheProcessHolds() throws {
        // Other tests run in parallel and free memory, so the footprint before and after can't be compared.
        // While 64 MB that were written to are held, the footprint must include them.
        let reader = TaskMemoryReader()
        var block = [UInt8](repeating: 1, count: 64_000_000)
        block[block.count - 1] = 2
        let bytes = try #require(reader.residentBytes())
        #expect(block.last == 2)
        #expect(bytes > 64_000_000)
    }
}
