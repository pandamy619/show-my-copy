import Foundation
import Testing

@testable import ShowMyCopy

/// One list of a row's actions feeds its context menu, its swipe buttons and its VoiceOver actions. Each action does
/// what the menu item always did and closes the swiped row.
@MainActor
struct RowActionTests {
    private let clock = ManualDate(Date(timeIntervalSince1970: 1_790_000_000))
    private let history: InMemoryHistoryStore
    private let deleter: EntryDeleterSpy

    init() {
        history = InMemoryHistoryStore(now: clock.read)
        deleter = EntryDeleterSpy(history: history)
    }

    private func makeModel() -> HistoryWindowModel {
        let model = HistoryWindowModel(history: history, deleter: deleter)
        model.prepareForPresentation()
        return model
    }

    private func record(_ content: ClipboardContent, concealed: Bool = false) throws -> ClipboardEntry {
        clock.advance(by: 1)
        let id = history.record(
            content, sourceApp: nil, at: clock.now, concealed: concealed, expiresAt: concealed ? clock.now + 600 : nil)
        return try #require(history.entries.first { $0.id == id })
    }

    private func entry(_ id: ClipboardEntry.ID) throws -> ClipboardEntry {
        try #require(history.entries.first { $0.id == id })
    }

    /// Opens the row of `entry` with a trackpad swipe past the hold threshold.
    private func swipeOpen(_ entry: ClipboardEntry, in model: HistoryWindowModel) {
        _ = model.swipeScrolled(RowSwipe.Scroll(phase: .began), on: entry)
        _ = model.swipeScrolled(RowSwipe.Scroll(phase: .changed, deltaX: -(RowSwipe.holdThreshold + 1)), on: entry)
        _ = model.swipeScrolled(RowSwipe.Scroll(phase: .ended), on: entry)
    }

    // MARK: - Which actions

    @Test func anEntryOffersShowPreviewPinAndDeleteInThatOrder() throws {
        let text = try record(.text("hello"))

        #expect(
            RowAction.offers(for: text) == [
                RowAction.Offer(action: .showPreview, isEnabled: true),
                RowAction.Offer(action: .pin, isEnabled: true),
                RowAction.Offer(action: .delete, isEnabled: true),
            ])
    }

    @Test func aPinnedEntryOffersUnpinInstead() throws {
        let text = try record(.text("hello"))
        history.setPinned(true, id: text.id)

        #expect(try RowAction.offers(for: entry(text.id)).map(\.action) == [.showPreview, .unpin, .delete])
    }

    @Test func aPasswordOffersNoPreviewAndADimmedPin() throws {
        let password = try record(.text("hunter2"), concealed: true)

        #expect(
            RowAction.offers(for: password) == [
                RowAction.Offer(action: .pin, isEnabled: false),
                RowAction.Offer(action: .delete, isEnabled: true),
            ])
    }

    @Test func everyKindOffersTheSameActions() throws {
        let kinds: [ClipboardContent] = [
            .text("text"), ContentFixtures.richText(), ContentFixtures.image(), ContentFixtures.files("/tmp/a"),
        ]
        for content in kinds {
            #expect(try RowAction.offers(for: record(content)).map(\.action) == [.showPreview, .pin, .delete])
        }
    }

    @Test func deleteIsLastAndTheOnlyDestructiveAction() throws {
        for entry in [try record(.text("a")), try record(.text("b"), concealed: true)] {
            let actions = RowAction.offers(for: entry).map(\.action)
            #expect(actions.last == .delete)
            #expect(actions.filter(\.isDestructive) == [.delete])
            #expect(actions.count <= RowAction.maximumCount)
        }
    }

    // MARK: - Performing

    @Test func showPreviewSelectsAndPreviewsTheEntryAndClosesTheRow() throws {
        let older = try record(.text("older"))
        _ = try record(.text("newer"))
        let model = makeModel()
        swipeOpen(older, in: model)
        #expect(model.swipe.swipedRowID == older.id)

        model.perform(.showPreview, on: older)

        #expect(model.preview.entryID == older.id)
        #expect(model.selectedEntry?.id == older.id)
        #expect(model.swipe.swipedRowID == nil)
    }

    @Test func pinAndUnpinToggleThePinAndCloseTheRow() throws {
        let text = try record(.text("hello"))
        let model = makeModel()
        swipeOpen(text, in: model)

        model.perform(.pin, on: text)
        #expect(try entry(text.id).isPinned)
        #expect(model.swipe.swipedRowID == nil)

        let pinned = try entry(text.id)
        swipeOpen(pinned, in: model)
        model.perform(.unpin, on: pinned)
        #expect(try !entry(text.id).isPinned)
        #expect(model.swipe.swipedRowID == nil)
    }

    @Test func pinOnAnEntryPinnedMeanwhileLeavesItPinned() throws {
        let text = try record(.text("hello"))
        let model = makeModel()
        history.setPinned(true, id: text.id)

        // The row still showed Pin.
        model.perform(.pin, on: text)

        #expect(try entry(text.id).isPinned)
    }

    @Test func aPasswordIsNotPinned() throws {
        let password = try record(.text("hunter2"), concealed: true)
        let model = makeModel()

        model.perform(.pin, on: password)

        #expect(try !entry(password.id).isPinned)
    }

    @Test func pinShowsThePinLimitNotice() throws {
        for index in 0..<RetentionPolicy.maximumPinned {
            history.setPinned(true, id: try record(.text("pin \(index)")).id)
        }
        let text = try record(.text("one more"))
        let model = makeModel()
        swipeOpen(text, in: model)

        clock.advance(by: 1)
        model.perform(.pin, on: text)

        #expect(model.showsPinLimitNotice)
        #expect(try entry(text.id).isPinned)
    }

    @Test func deleteDeletesLikeCommandDeleteAndClosesTheRow() throws {
        let text = try record(.text("hello"))
        let model = makeModel()
        swipeOpen(text, in: model)

        model.perform(.delete, on: text)

        #expect(deleter.deletedIDs == [text.id])
        #expect(model.swipe.swipedRowID == nil)
        #expect(model.handleKey(.undo, isCaretAtEnd: true) == .handled)
        #expect(model.items.map(\.id) == [text.id])
    }
}
