import Foundation
import Testing

@testable import ShowMyCopy

/// When a pin or an Undo in the history window unpins the oldest pinned entry to keep `RetentionPolicy.maximumPinned`,
/// the window says so in one line, until the next pin or Undo, the user dismisses it or the window opens again.
@MainActor
struct HistoryWindowPinLimitTests {
    private let clock = ManualDate(Date(timeIntervalSince1970: 1_790_000_100))
    private let history: InMemoryHistoryStore
    private let deleter: EntryDeleterSpy
    private let limit = RetentionPolicy.maximumPinned

    init() {
        history = InMemoryHistoryStore(now: clock.read)
        deleter = EntryDeleterSpy(history: history)
    }

    /// "pin 0" to "pin 49" pinned in that order, then "one" and "two" copied, "two" on the clipboard and selected.
    private func makeModel() -> HistoryWindowModel {
        for index in 0..<limit {
            clock.advance(by: 1)
            let id = history.record(text: "pin \(index)", sourceApp: nil, at: clock.now)
            history.setPinned(true, id: id)
        }
        clock.advance(by: 1)
        history.record(text: "one", sourceApp: nil, at: clock.now)
        clock.advance(by: 1)
        history.record(text: "two", sourceApp: nil, at: clock.now)
        let model = HistoryWindowModel(history: history, deleter: deleter)
        model.prepareForPresentation()
        return model
    }

    private func entry(_ text: String) throws -> ClipboardEntry {
        try #require(history.entries.first { $0.text == text })
    }

    @Test func pinningTheFiftyFirstEntryShowsTheNotice() throws {
        let model = makeModel()
        #expect(!model.showsPinLimitNotice)
        #expect(model.selectedEntry?.text == "two")

        clock.advance(by: 1)
        #expect(model.handleKey(.pin, isCaretAtEnd: true) == .handled)

        #expect(model.showsPinLimitNotice)
        #expect(model.pinLimitNoticeCount == 1)
        #expect(model.sections.pinned.count == limit)
        #expect(model.sections.history.first?.text == "pin 0")
        #expect(model.selectedEntry?.text == "two")
    }

    @Test func pinningUnderTheLimitOrUnpinningShowsNoNotice() throws {
        let model = makeModel()
        clock.advance(by: 1)
        model.togglePin(try entry("pin 10"))
        #expect(!model.showsPinLimitNotice)

        clock.advance(by: 1)
        model.togglePin(try entry("two"))
        #expect(!model.showsPinLimitNotice)
        #expect(model.pinLimitNoticeCount == 0)
    }

    @Test func theNextPinWithoutAReplacementHidesTheNotice() throws {
        let model = makeModel()
        clock.advance(by: 1)
        model.togglePin(try entry("two"))
        #expect(model.showsPinLimitNotice)

        clock.advance(by: 1)
        model.togglePin(try entry("two"))
        #expect(!model.showsPinLimitNotice)
    }

    @Test func eachReplacementCountsAgainSoItIsAnnouncedAgain() throws {
        let model = makeModel()
        clock.advance(by: 1)
        model.togglePin(try entry("two"))
        clock.advance(by: 1)
        model.togglePin(try entry("one"))

        #expect(model.showsPinLimitNotice)
        #expect(model.pinLimitNoticeCount == 2)
        #expect(model.sections.history.map(\.text).prefix(2) == ["pin 1", "pin 0"])
    }

    @Test func dismissingOrOpeningTheWindowAgainHidesTheNotice() throws {
        let model = makeModel()
        clock.advance(by: 1)
        model.togglePin(try entry("two"))
        model.showsPinLimitNotice = false
        #expect(!model.showsPinLimitNotice)

        clock.advance(by: 1)
        model.togglePin(try entry("one"))
        #expect(model.showsPinLimitNotice)
        model.prepareForPresentation()
        #expect(!model.showsPinLimitNotice)
    }

    @Test func undoingADeleteThatUnpinsTheOldestShowsTheNotice() throws {
        let model = makeModel()
        model.delete(try entry("pin 10"))
        clock.advance(by: 1)
        model.togglePin(try entry("two"))
        #expect(!model.showsPinLimitNotice)

        clock.advance(by: 1)
        #expect(model.handleKey(.undo, isCaretAtEnd: true) == .handled)

        #expect(model.showsPinLimitNotice)
        #expect(try entry("pin 10").isPinned)
        #expect(try !entry("pin 0").isPinned)
    }

    @Test func undoingADeleteUnderTheLimitShowsNoNotice() throws {
        let model = makeModel()
        model.delete(try entry("one"))

        model.undoDelete()

        #expect(!model.showsPinLimitNotice)
        #expect(model.pinLimitNoticeCount == 0)
    }
}
