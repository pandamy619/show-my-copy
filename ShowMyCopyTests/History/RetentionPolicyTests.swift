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

    @Test func hasNoByteLimitByDefault() {
        #expect(RetentionPolicy.default.byteLimit == nil)
        let all = (0..<10).map { index in
            ClipboardEntry(text: String(repeating: "x", count: 100_000), date: start + Double(index), sourceApp: nil)
        }
        #expect(RetentionPolicy.default.removedCount(from: all) == 0)
    }

    @Test func byteLimitRemovesTheOldestEntriesThatDoNotFit() {
        // "item 9" ... "item 0": six bytes each.
        let policy = RetentionPolicy(entryLimit: 100, byteLimit: 20)
        #expect(policy.kept(entries(10)).map(\.text) == ["item 9", "item 8", "item 7"])
        #expect(policy.removedCount(from: entries(10)) == 7)
    }

    @Test func entryThatFitsExactlyIsKept() {
        let policy = RetentionPolicy(entryLimit: 100, byteLimit: 18)
        #expect(policy.kept(entries(10)).count == 3)
    }

    @Test func noOlderEntryIsKeptAfterOneThatDoesNotFit() {
        let all = [
            ClipboardEntry(text: "new", date: start + 2, sourceApp: nil),
            ClipboardEntry(text: String(repeating: "x", count: 50), date: start + 1, sourceApp: nil),
            ClipboardEntry(text: "old", date: start, sourceApp: nil),
        ]
        #expect(RetentionPolicy(byteLimit: 10).kept(all).map(\.text) == ["new"])
    }

    @Test func bothLimitsApply() {
        #expect(RetentionPolicy(entryLimit: 10, byteLimit: 1000).kept(entries(12)).count == 10)
        // "item 11" and "item 10" are seven bytes, the rest six: 7 + 7 + 6 + 6 fits in 30, a fifth does not.
        #expect(RetentionPolicy(entryLimit: 10, byteLimit: 30).kept(entries(12)).count == 4)
    }

    @Test func pinnedEntriesDoNotCountTowardTheByteLimit() {
        var all = entries(10)
        all[9].isPinned = true
        all[0].isPinned = true
        let kept = RetentionPolicy(entryLimit: 100, byteLimit: 12).kept(all)
        #expect(kept.map(\.text) == ["item 9", "item 8", "item 7", "item 0"])
    }

    @Test func negativeByteLimitKeepsOnlyPinnedEntries() {
        var all = entries(3)
        all[1].isPinned = true
        let policy = RetentionPolicy(byteLimit: -1)
        #expect(policy.byteLimit == 0)
        #expect(policy.kept(all).map(\.text) == ["item 1"])
    }

    @Test func changingOneLimitKeepsTheOther() {
        let policy = RetentionPolicy(entryLimit: 20, byteLimit: 500)
        #expect(policy.withEntryLimit(30) == RetentionPolicy(entryLimit: 30, byteLimit: 500))
        #expect(policy.withByteLimit(nil) == RetentionPolicy(entryLimit: 20))
    }
}

@MainActor
struct HistoryByteLimitTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func historyKeepsItsByteLimit() {
        let history = ClipboardHistory(retention: RetentionPolicy(byteLimit: 20))
        for index in 0..<5 {
            history.record(text: "item \(index)", sourceApp: nil, at: start + Double(index))
        }
        #expect(history.entries.map(\.text) == ["item 4", "item 3", "item 2"])
        #expect(history.stats().totalBytes == 18)
    }

    @Test func changingTheEntryLimitKeepsTheByteLimit() {
        let history = ClipboardHistory(retention: RetentionPolicy(byteLimit: 20))
        history.setLimit(200)
        #expect(history.retention == RetentionPolicy(entryLimit: 200, byteLimit: 20))
    }

    @Test func entryLargerThanTheByteLimitIsNotKept() {
        let history = ClipboardHistory(retention: RetentionPolicy(byteLimit: 4))
        history.record(text: "too long", sourceApp: nil, at: start)
        #expect(history.entries.isEmpty)
        #expect(history.currentEntryID == nil)
    }
}
