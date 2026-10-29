import Foundation
import Testing

@testable import ShowMyCopy

/// The pick, confirm and cancel flow that every limit control in Settings shares.
@MainActor
struct LimitDraftTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// A history of 15 entries, "item 0" (oldest) to "item 14", that allows 1000, and its settings, both at a
    /// clock a day later.
    private func withSettings(_ body: (InMemoryHistoryStore, HistorySettings) throws -> Void) throws {
        let now = start + 86_400
        try TestDefaults.with { defaults in
            let history = InMemoryHistoryStore(retention: RetentionPolicy(entryLimit: 1000), now: { now })
            for index in 0..<15 {
                history.record(text: "item \(index)", sourceApp: nil, at: start + Double(index))
            }
            try body(history, HistorySettings(history: history, defaults: defaults, now: { now }))
        }
    }

    @Test func showsTheLimitInEffect() throws {
        try withSettings { _, settings in
            #expect(LimitDraft(settings: settings, limit: .entries).value == 1000)
            #expect(LimitDraft(settings: settings, limit: .size).value == .noLimit)
            #expect(LimitDraft(settings: settings, limit: .age).value == .off)
        }
    }

    @Test func aValueThatRemovesNothingIsAppliedAtOnce() throws {
        try withSettings { history, settings in
            let draft = LimitDraft(settings: settings, limit: .entries)
            draft.value = 20
            #expect(draft.pending == nil)
            #expect(history.limit == 20)
            #expect(history.entries.count == 15)
        }
    }

    @Test func aValueThatRemovesEntriesWaitsForConfirmation() throws {
        try withSettings { history, settings in
            let draft = LimitDraft(settings: settings, limit: .entries)
            draft.value = 10
            #expect(draft.value == 10)
            #expect(draft.pending == LimitChange(limit: 10, removedCount: 5, freedBytes: 30, keptPinnedCount: 0))
            #expect(history.limit == 1000)

            draft.confirm()
            #expect(draft.pending == nil)
            #expect(history.limit == 10)
            #expect(history.entries.count == 10)
            #expect(draft.value == 10)
        }
    }

    @Test func cancellingShowsTheLimitInEffectAgain() throws {
        try withSettings { history, settings in
            let draft = LimitDraft(settings: settings, limit: .entries)
            draft.value = 10
            draft.cancel()
            #expect(draft.pending == nil)
            #expect(draft.value == 1000)
            #expect(history.entries.count == 15)
        }
    }

    @Test func aValueOutsideTheRangeShowsAsTheValueItBecomes() throws {
        try withSettings { history, settings in
            let draft = LimitDraft(settings: settings, limit: .entries)
            draft.value = 5000
            #expect(draft.value == 1000)
            #expect(draft.pending == nil)

            draft.value = 1
            #expect(draft.value == 10)
            #expect(draft.pending?.limit == 10)
            #expect(history.limit == 1000)
        }
    }

    @Test func historyChangesUpdateThePendingValue() throws {
        try withSettings { history, settings in
            let draft = LimitDraft(settings: settings, limit: .entries)
            draft.value = 10
            history.record(text: "item 15", sourceApp: nil, at: start + 15)
            draft.historyChanged()
            #expect(draft.pending?.removedCount == 6)

            history.clear()
            draft.historyChanged()
            // It removes nothing now, so it is applied without asking.
            #expect(draft.pending == nil)
            #expect(history.limit == 10)
        }
    }

    @Test func resetDropsThePendingValue() throws {
        try withSettings { history, settings in
            let draft = LimitDraft(settings: settings, limit: .size)
            draft.value = .megabytes100
            #expect(draft.pending == nil)
            #expect(history.retention.byteLimit == 100_000_000)

            let entries = LimitDraft(settings: settings, limit: .entries)
            entries.value = 10
            entries.reset()
            #expect(entries.pending == nil)
            #expect(entries.value == 1000)
        }
    }

    @Test func worksForTheAgeLimit() throws {
        try withSettings { history, settings in
            let draft = LimitDraft(settings: settings, limit: .age)
            draft.value = .after(.seconds(3600))
            // Every entry was copied a day ago, so the user is asked first.
            #expect(draft.pending?.removedCount == 15)
            draft.confirm()
            #expect(history.entries.isEmpty)
            #expect(settings.value(of: .age) == .after(.seconds(3600)))
        }
    }
}
