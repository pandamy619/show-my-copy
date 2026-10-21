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
}
