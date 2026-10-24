import Foundation

/// A small least-recently-used cache, bounded by the number of values and by their total cost (such as bytes).
///
/// Inserting past either limit drops the values used longest ago. A value that alone costs more than the cost limit
/// is not kept at all. Meant for a few hundred values: finding the oldest one walks them all.
struct BoundedCache<Key: Hashable, Value> {
    private struct Slot {
        let value: Value
        let cost: Int
        var lastUse: UInt64
    }

    let countLimit: Int
    let costLimit: Int

    private var slots: [Key: Slot] = [:]
    private var clock: UInt64 = 0
    private(set) var totalCost = 0

    init(countLimit: Int, costLimit: Int) {
        self.countLimit = max(countLimit, 0)
        self.costLimit = max(costLimit, 0)
    }

    var count: Int {
        slots.count
    }

    var isEmpty: Bool {
        slots.isEmpty
    }

    /// The value for `key`, which then counts as just used.
    mutating func value(for key: Key) -> Value? {
        guard var slot = slots[key] else {
            return nil
        }
        clock += 1
        slot.lastUse = clock
        slots[key] = slot
        return slot.value
    }

    /// Whether a value is kept for `key`, without counting as a use.
    func contains(_ key: Key) -> Bool {
        slots[key] != nil
    }

    /// Keeps `value` for `key`, replacing what was kept for it, then drops the oldest values until both limits hold.
    mutating func insert(_ value: Value, for key: Key, cost: Int = 0) {
        let cost = max(cost, 0)
        removeValue(for: key)
        guard cost <= costLimit, countLimit > 0 else {
            return
        }
        clock += 1
        slots[key] = Slot(value: value, cost: cost, lastUse: clock)
        totalCost += cost
        while slots.count > countLimit || totalCost > costLimit {
            guard let oldest = slots.min(by: { $0.value.lastUse < $1.value.lastUse })?.key else {
                break
            }
            removeValue(for: oldest)
        }
    }

    mutating func removeValue(for key: Key) {
        if let removed = slots.removeValue(forKey: key) {
            totalCost -= removed.cost
        }
    }
}
