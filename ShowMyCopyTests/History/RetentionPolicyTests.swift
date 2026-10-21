import Foundation
import Testing

@testable import ShowMyCopy

struct RetentionPolicyTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// Entries newest first, like the history keeps them.
    private func entries(_ count: Int) -> [ClipboardEntry] {
        (0..<count).reversed().map { index in
            ClipboardEntry(text: "item \(index)", date: start + Double(index), sourceApp: nil)
        }
    }

    @Test func defaultKeepsFiftyEntries() {
        #expect(RetentionPolicy.default.entryLimit == 50)
        #expect(RetentionPolicy().entryLimit == RetentionPolicy.defaultEntryLimit)
    }

    @Test(arguments: [(-5, 10), (0, 10), (10, 10), (500, 500), (1000, 1000), (5000, 1000)])
    func entryLimitIsClamped(requested: Int, expected: Int) {
        #expect(RetentionPolicy.clamped(requested) == expected)
        #expect(RetentionPolicy(entryLimit: requested).entryLimit == expected)
        #expect(RetentionPolicy.default.withEntryLimit(requested).entryLimit == expected)
    }

    @Test func keepsTheNewestEntriesWithinTheLimit() {
        let policy = RetentionPolicy(entryLimit: 10)
        let kept = policy.kept(entries(12))
        #expect(kept.map(\.text) == (2..<12).reversed().map { "item \($0)" })
        #expect(policy.removedCount(from: entries(12)) == 2)
    }

    @Test func removesNothingUnderTheLimit() {
        let policy = RetentionPolicy(entryLimit: 10)
        #expect(policy.kept(entries(10)).count == 10)
        #expect(policy.removedCount(from: entries(3)) == 0)
        #expect(policy.removedCount(from: []) == 0)
    }

    @Test func neverRemovesPinnedEntries() {
        var all = entries(14)
        // Pin the two oldest and one in the middle.
        for index in [13, 12, 5] {
            all[index].isPinned = true
        }
        let kept = RetentionPolicy(entryLimit: 10).kept(all)
        #expect(kept.filter(\.isPinned).count == 3)
        #expect(kept.map(\.text).contains("item 0"))
        #expect(kept.map(\.text).contains("item 1"))
    }

    @Test func pinnedEntriesDoNotCountTowardTheLimit() {
        var all = entries(14)
        for index in [13, 12, 5] {
            all[index].isPinned = true
        }
        let policy = RetentionPolicy(entryLimit: 10)
        let kept = policy.kept(all)
        // Ten unpinned entries plus the three pinned ones, in their original order.
        #expect(kept.count == 13)
        #expect(kept.filter { !$0.isPinned }.count == 10)
        #expect(kept.map(\.id) == all.filter { kept.map(\.id).contains($0.id) }.map(\.id))
        #expect(kept.last?.text == "item 0")
        #expect(policy.removedCount(from: all) == 1)
    }
}
