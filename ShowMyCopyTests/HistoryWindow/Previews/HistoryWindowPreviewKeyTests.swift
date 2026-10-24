import Foundation
import Testing

@testable import ShowMyCopy

@MainActor
struct HistoryWindowPreviewKeyTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// History with "third" on top, then "second", then "first".
    private func makeModel(missing: Set<String> = []) -> HistoryWindowModel {
        let history = ClipboardHistory()
        for (index, text) in ["first", "second", "third"].enumerated() {
            history.record(text: text, sourceApp: nil, at: start + Double(index))
        }
        let model = HistoryWindowModel(
            history: history,
            previews: PreviewServices(fileAvailability: FakeAvailabilityChecker(missing: missing))
        )
        model.prepareForPresentation()
        return model
    }

    private func previewedText(_ model: HistoryWindowModel) -> String? {
        guard case .text(let text) = model.preview.content else {
            return nil
        }
        return text
    }

    @Test func rightArrowOpensThePreviewOfTheSelectedEntry() {
        let model = makeModel()
        #expect(model.handleKey(.right, isCaretAtEnd: true) == .handled)
        #expect(model.preview.entryID == model.selectedEntry?.id)
        #expect(previewedText(model) == "third")
        #expect(model.previewedEntry?.id == model.selectedEntry?.id)
    }

    @Test func rightArrowMovesTheCaretWhenItIsNotAtTheEnd() {
        let model = makeModel()
        #expect(model.handleKey(.right, isCaretAtEnd: false) == .ignored)
        #expect(!model.preview.isOpen)
    }

    @Test func rightArrowWithThePreviewOpenIsLeftToTheSearchField() {
        let model = makeModel()
        _ = model.handleKey(.right, isCaretAtEnd: true)
        #expect(model.handleKey(.right, isCaretAtEnd: true) == .ignored)
        #expect(model.preview.isOpen)
    }

    @Test func leftArrowClosesThePreviewOrMovesTheCaret() {
        let model = makeModel()
        #expect(model.handleKey(.left, isCaretAtEnd: true) == .ignored)
        _ = model.handleKey(.right, isCaretAtEnd: true)
        #expect(model.handleKey(.left, isCaretAtEnd: true) == .handled)
        #expect(!model.preview.isOpen)
    }

    @Test func escapeClosesThePreviewFirstThenTheWindow() {
        let model = makeModel()
        _ = model.handleKey(.right, isCaretAtEnd: true)
        #expect(model.handleKey(.escape, isCaretAtEnd: true) == .handled)
        #expect(!model.preview.isOpen)
        #expect(model.handleKey(.escape, isCaretAtEnd: true) == .close)
    }

    @Test func arrowsMoveTheSelectionAndThePreviewFollows() {
        let model = makeModel()
        #expect(model.handleKey(.down, isCaretAtEnd: true) == .handled)
        #expect(model.selectedEntry?.text == "second")
        #expect(!model.preview.isOpen)

        _ = model.handleKey(.right, isCaretAtEnd: true)
        _ = model.handleKey(.down, isCaretAtEnd: true)
        #expect(model.selectedEntry?.text == "first")
        #expect(previewedText(model) == "first")
        _ = model.handleKey(.up, isCaretAtEnd: false)
        #expect(previewedText(model) == "second")
    }

    @Test func returnChoosesTheSelectedEntryWithOrWithoutPreview() throws {
        let model = makeModel()
        let selected = try #require(model.selectedEntry)
        #expect(model.handleKey(.return, isCaretAtEnd: true) == .choose(selected))
        _ = model.handleKey(.right, isCaretAtEnd: true)
        #expect(model.handleKey(.return, isCaretAtEnd: true) == .choose(selected))

        let empty = HistoryWindowModel(history: ClipboardHistory())
        #expect(empty.handleKey(.return, isCaretAtEnd: true) == .handled)
        #expect(empty.handleKey(.right, isCaretAtEnd: true) == .ignored)
    }

    @Test func passwordsAreNotPreviewed() throws {
        let model = makeModel()
        let top = try #require(model.items.first)
        model.history.conceal(id: top.id, expiresAt: start + 3600)
        #expect(model.handleKey(.right, isCaretAtEnd: true) == .ignored)
        #expect(!model.preview.isOpen)

        // Moving onto a password from an open preview closes the preview.
        _ = model.handleKey(.down, isCaretAtEnd: true)
        _ = model.handleKey(.right, isCaretAtEnd: true)
        #expect(model.preview.isOpen)
        _ = model.handleKey(.up, isCaretAtEnd: true)
        #expect(!model.preview.isOpen)
    }

    @Test func typingClosesThePreview() {
        let model = makeModel()
        _ = model.handleKey(.right, isCaretAtEnd: true)
        model.query = "sec"
        #expect(!model.preview.isOpen)
    }

    @Test func showingTheWindowAgainClosesThePreview() {
        let model = makeModel()
        _ = model.handleKey(.right, isCaretAtEnd: true)
        model.prepareForPresentation()
        #expect(!model.preview.isOpen)
    }

    @Test func showPreviewOfAnEntrySelectsIt() throws {
        let model = makeModel()
        let last = try #require(model.items.last)
        model.showPreview(of: last)
        #expect(model.selectedEntry?.id == last.id)
        #expect(previewedText(model) == "first")
    }

    @Test func previewedEntryIsNilOnceTheEntryIsGone() throws {
        let model = makeModel()
        _ = model.handleKey(.right, isCaretAtEnd: true)
        let shown = try #require(model.previewedEntry)
        model.history.remove(id: shown.id)
        #expect(model.previewedEntry == nil)
    }

    @Test func rowAvailabilityIsCheckedForItsFilesOnly() async {
        let model = makeModel(missing: ["/tmp/gone"])
        #expect(await model.availability(of: [ContentFixtures.file("/tmp/here")]) == .available)
        #expect(
            await model.availability(of: [ContentFixtures.file("/tmp/here"), ContentFixtures.file("/tmp/gone")])
                == .mayBeUnavailable)
    }
}
