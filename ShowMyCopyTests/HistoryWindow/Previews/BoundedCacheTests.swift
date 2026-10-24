import Testing

@testable import ShowMyCopy

struct BoundedCacheTests {
    @Test func keepsValuesUntilTheCountLimit() {
        var cache = BoundedCache<String, Int>(countLimit: 2, costLimit: 100)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        cache.insert(3, for: "c")
        #expect(cache.count == 2)
        #expect(!cache.contains("a"))
        #expect(cache.value(for: "b") == 2)
        #expect(cache.value(for: "c") == 3)
    }

    @Test func dropsTheLeastRecentlyUsedValue() {
        var cache = BoundedCache<String, Int>(countLimit: 2, costLimit: 100)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        // Reading "a" makes "b" the oldest.
        #expect(cache.value(for: "a") == 1)
        cache.insert(3, for: "c")
        #expect(cache.contains("a"))
        #expect(!cache.contains("b"))
        #expect(cache.contains("c"))
    }

    @Test func containsDoesNotCountAsAUse() {
        var cache = BoundedCache<String, Int>(countLimit: 2, costLimit: 100)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        #expect(cache.contains("a"))
        cache.insert(3, for: "c")
        #expect(!cache.contains("a"))
    }

    @Test func keepsTheTotalCostWithinTheLimit() {
        var cache = BoundedCache<String, Int>(countLimit: 10, costLimit: 100)
        cache.insert(1, for: "a", cost: 40)
        cache.insert(2, for: "b", cost: 40)
        #expect(cache.totalCost == 80)
        cache.insert(3, for: "c", cost: 40)
        #expect(!cache.contains("a"))
        #expect(cache.totalCost == 80)
        #expect(cache.count == 2)
    }

    @Test func doesNotKeepAValueCostingMoreThanTheLimit() {
        var cache = BoundedCache<String, Int>(countLimit: 10, costLimit: 100)
        cache.insert(1, for: "a", cost: 10)
        cache.insert(2, for: "huge", cost: 101)
        #expect(!cache.contains("huge"))
        // Nothing else was dropped to make room for it.
        #expect(cache.contains("a"))
        #expect(cache.totalCost == 10)
    }

    @Test func replacingAValueReplacesItsCost() {
        var cache = BoundedCache<String, Int>(countLimit: 10, costLimit: 100)
        cache.insert(1, for: "a", cost: 30)
        cache.insert(2, for: "a", cost: 50)
        #expect(cache.count == 1)
        #expect(cache.totalCost == 50)
        #expect(cache.value(for: "a") == 2)

        cache.removeValue(for: "a")
        #expect(cache.isEmpty)
        #expect(cache.totalCost == 0)
    }

    @Test func zeroCountLimitKeepsNothing() {
        var cache = BoundedCache<String, Int>(countLimit: 0, costLimit: 100)
        cache.insert(1, for: "a")
        #expect(cache.isEmpty)
    }
}
