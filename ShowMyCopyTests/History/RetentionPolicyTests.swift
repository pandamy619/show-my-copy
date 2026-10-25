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
        let kept = policy.kept(entries(12), at: start)
        #expect(kept.map(\.text) == (2..<12).reversed().map { "item \($0)" })
        #expect(policy.removedCount(from: entries(12), at: start) == 2)
    }

    @Test func removesNothingUnderTheLimit() {
        let policy = RetentionPolicy(entryLimit: 10)
        #expect(policy.kept(entries(10), at: start).count == 10)
        #expect(policy.removedCount(from: entries(3), at: start) == 0)
        #expect(policy.removedCount(from: [], at: start) == 0)
    }

    @Test func neverRemovesPinnedEntries() {
        var all = entries(14)
        // Pin the two oldest and one in the middle.
        for index in [13, 12, 5] {
            all[index].isPinned = true
        }
        let kept = RetentionPolicy(entryLimit: 10).kept(all, at: start)
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
        let kept = policy.kept(all, at: start)
        // Ten unpinned entries plus the three pinned ones, in their original order.
        #expect(kept.count == 13)
        #expect(kept.filter { !$0.isPinned }.count == 10)
        #expect(kept.map(\.id) == all.filter { kept.map(\.id).contains($0.id) }.map(\.id))
        #expect(kept.last?.text == "item 0")
        #expect(policy.removedCount(from: all, at: start) == 1)
    }

    @Test func hasNoByteLimitByDefault() {
        #expect(RetentionPolicy.default.byteLimit == nil)
        let all = (0..<10).map { index in
            ClipboardEntry(text: String(repeating: "x", count: 100_000), date: start + Double(index), sourceApp: nil)
        }
        #expect(RetentionPolicy.default.removedCount(from: all, at: start) == 0)
    }

    @Test func byteLimitRemovesTheOldestEntriesThatDoNotFit() {
        // "item 9" ... "item 0": six bytes each.
        let policy = RetentionPolicy(entryLimit: 100, byteLimit: 20)
        #expect(policy.kept(entries(10), at: start).map(\.text) == ["item 9", "item 8", "item 7"])
        #expect(policy.removedCount(from: entries(10), at: start) == 7)
    }

    @Test func entryThatFitsExactlyIsKept() {
        let policy = RetentionPolicy(entryLimit: 100, byteLimit: 18)
        #expect(policy.kept(entries(10), at: start).count == 3)
    }

    @Test func noOlderEntryIsKeptAfterOneThatDoesNotFit() {
        let all = [
            ClipboardEntry(text: "new", date: start + 2, sourceApp: nil),
            ClipboardEntry(text: String(repeating: "x", count: 50), date: start + 1, sourceApp: nil),
            ClipboardEntry(text: "old", date: start, sourceApp: nil),
        ]
        #expect(RetentionPolicy(byteLimit: 10).kept(all, at: start).map(\.text) == ["new"])
    }

    @Test func bothLimitsApply() {
        #expect(RetentionPolicy(entryLimit: 10, byteLimit: 1000).kept(entries(12), at: start).count == 10)
        // "item 11" and "item 10" are seven bytes, the rest six: 7 + 7 + 6 + 6 fits in 30, a fifth does not.
        #expect(RetentionPolicy(entryLimit: 10, byteLimit: 30).kept(entries(12), at: start).count == 4)
    }

    @Test func pinnedEntriesDoNotCountTowardTheByteLimit() {
        var all = entries(10)
        all[9].isPinned = true
        all[0].isPinned = true
        let kept = RetentionPolicy(entryLimit: 100, byteLimit: 12).kept(all, at: start)
        #expect(kept.map(\.text) == ["item 9", "item 8", "item 7", "item 0"])
    }

    @Test func negativeByteLimitKeepsOnlyPinnedEntries() {
        var all = entries(3)
        all[1].isPinned = true
        let policy = RetentionPolicy(byteLimit: -1)
        #expect(policy.byteLimit == 0)
        #expect(policy.kept(all, at: start).map(\.text) == ["item 1"])
    }

    @Test func changingOneLimitKeepsTheOthers() {
        let policy = RetentionPolicy(entryLimit: 20, byteLimit: 500, maxAge: .seconds(60))
        #expect(policy.withEntryLimit(30) == RetentionPolicy(entryLimit: 30, byteLimit: 500, maxAge: .seconds(60)))
        #expect(policy.withByteLimit(nil) == RetentionPolicy(entryLimit: 20, maxAge: .seconds(60)))
        #expect(policy.withMaxAge(nil) == RetentionPolicy(entryLimit: 20, byteLimit: 500))
        #expect(policy.withMaxAge(.seconds(5)).maxAge == .seconds(5))
    }

    // MARK: - Age

    @Test func hasNoAgeLimitByDefault() {
        let old = [ClipboardEntry(text: "old", date: start - 1_000_000, sourceApp: nil)]
        #expect(RetentionPolicy.default.maxAge == nil)
        #expect(RetentionPolicy.default.kept(old, at: start) == old)
        #expect(!RetentionPolicy.default.isPastMaxAge(old[0], at: start))
    }

    /// `entries(10)` were copied at `start` + 0 to 9 seconds.
    @Test func removesEntriesCopiedAtLeastMaxAgeAgo() {
        let policy = RetentionPolicy(maxAge: .seconds(60))
        #expect(policy.kept(entries(10), at: start + 63).map(\.text) == (4..<10).reversed().map { "item \($0)" })
        #expect(policy.removedCount(from: entries(10), at: start + 59) == 0)
        #expect(policy.removedCount(from: entries(10), at: start + 1000) == 10)
        #expect(policy.isPastMaxAge(entries(1)[0], at: start + 60))
        #expect(!policy.isPastMaxAge(entries(1)[0], at: start + 59.5))
    }

    @Test func pinnedEntriesHaveNoAgeLimit() {
        var all = entries(3)
        all[2].isPinned = true
        let policy = RetentionPolicy(maxAge: .seconds(60))
        #expect(policy.kept(all, at: start + 1000).map(\.text) == ["item 0"])
        #expect(!policy.isPastMaxAge(all[2], at: start + 1000))
    }

    @Test func entriesPastTheAgeLimitDoNotCountTowardTheOtherLimits() {
        var all = entries(12)
        // The two at the top were copied long ago, as when the clock was set back since: they go, and the ten
        // below them are all kept.
        all[0].date = start - 1000
        all[1].date = start - 1000
        let policy = RetentionPolicy(entryLimit: 10, maxAge: .seconds(60))
        #expect(policy.kept(all, at: start + 30).map(\.text) == (0..<10).reversed().map { "item \($0)" })
    }

    @Test func negativeMaxAgeIsZero() {
        let policy = RetentionPolicy(maxAge: .seconds(-5))
        #expect(policy.maxAge == .zero)
        #expect(policy.kept(entries(2), at: start + 1).map(\.text) == [])
    }
}
