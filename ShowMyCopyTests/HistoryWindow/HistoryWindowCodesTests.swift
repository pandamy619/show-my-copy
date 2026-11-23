import Foundation
import Testing

@testable import ShowMyCopy

/// The Codes section of the history window: where the accounts are listed, how they are found and chosen.
@MainActor
struct HistoryWindowCodesTests {
    private let history = InMemoryHistoryStore()
    private let codes = CodeAccountStore(persistence: InMemoryCodeAccounts(), now: { CodeFixtures.date })
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let github = CodeFixtures.account()
    private let google = CodeFixtures.account(
        issuer: "Google", name: "me@gmail.com", secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")

    /// A model with the Codes section shown, as after the user clicked the button next to the gear.
    private func makeModel(pastes: Bool = false, showsCodes: Bool = true) async -> HistoryWindowModel {
        await codes.add([github, google])
        let model = HistoryWindowModel(
            history: history, deleter: EntryDeleterSpy(history: history), codes: codes,
            pastesAfterChoosing: { pastes })
        model.showsCodes = showsCodes
        return model
    }

    @Test func codesAreHiddenUntilAskedForAndHiddenAgainWhenTheWindowOpens() async throws {
        history.record(text: "current", sourceApp: nil, at: start)
        let model = await makeModel(showsCodes: false)
        #expect(model.hasCodes)
        #expect(model.codeRows.isEmpty)
        #expect(model.rows.map(\.entry?.text) == ["current"])

        model.toggleCodes()
        #expect(model.showsCodes)
        #expect(model.rows.count == 3)
        #expect(model.rows.first?.code == stored(github))
        model.toggleCodes()
        #expect(model.rows.count == 1)

        model.toggleCodes()
        model.prepareForPresentation()
        #expect(!model.showsCodes)
        #expect(model.rows.count == 1)
    }

    @Test func anEmptyHistoryWithHiddenCodesShowsNothing() async {
        let model = await makeModel(showsCodes: false)
        #expect(!model.showsEntries)
        model.toggleCodes()
        #expect(model.showsEntries)
    }

    private func stored(_ account: OneTimeCodeAccount) -> CodeAccount? {
        codes.accounts.first { $0.account == account }
    }

    @Test func codesAreListedFirstUnderTheSearchBar() async throws {
        history.record(text: "first", sourceApp: nil, at: start)
        let pinnedID = history.record(text: "pinned", sourceApp: nil, at: start + 1)
        history.setPinned(true, id: pinnedID)
        history.record(text: "current", sourceApp: nil, at: start + 2)
        let model = await makeModel()

        let names = model.rows.map { row in row.entry?.text ?? row.code?.displayName ?? "" }
        #expect(names == ["GitHub (octocat)", "Google (me@gmail.com)", "current", "pinned", "first"])
        #expect(model.items.map(\.text) == ["current", "pinned", "first"])
        #expect(model.showsEntries)
    }

    @Test func codesAreListedWithAnEmptyHistory() async throws {
        let model = await makeModel()
        #expect(model.rows.map(\.code?.displayName) == ["GitHub (octocat)", "Google (me@gmail.com)"])
        #expect(model.showsEntries)
        #expect(model.selectedCode == stored(github))
        #expect(model.selectedEntry == nil)
        #expect(model.selectedIndex == nil)
    }

    @Test func theArrowKeysWalkCodesAndEntries() async throws {
        history.record(text: "current", sourceApp: nil, at: start)
        let model = await makeModel(showsCodes: false)
        #expect(model.selectedEntry?.text == "current")

        // Showing the codes selects the first one, so Return copies it at once.
        model.toggleCodes()
        #expect(model.selectedCode == stored(github))
        #expect(model.selectedRowID == stored(github)?.id)
        _ = model.handleKey(.up, isCaretAtEnd: true)
        #expect(model.selectedCode == stored(github))
        _ = model.handleKey(.down, isCaretAtEnd: true)
        #expect(model.selectedCode == stored(google))
        _ = model.handleKey(.down, isCaretAtEnd: true)
        #expect(model.selectedEntry?.text == "current")
        _ = model.handleKey(.down, isCaretAtEnd: true)
        #expect(model.selectedEntry?.text == "current")
        _ = model.handleKey(.up, isCaretAtEnd: true)
        #expect(model.selectedCode == stored(google))
        // Hiding them selects the first row again.
        model.toggleCodes()
        #expect(model.selectedEntry?.text == "current")
    }

    @Test func returnOnACodeCopiesIt() async throws {
        let model = await makeModel(pastes: true)
        let github = try #require(stored(github))

        #expect(model.handleKey(.return, isCaretAtEnd: true) == .copyCode(github, pastes: true))
        #expect(model.handleKey(.optionReturn, isCaretAtEnd: true) == .copyCode(github, pastes: false))
    }

    @Test func searchFindsCodesByTheirNamesOnly() async throws {
        history.record(text: "github notes", sourceApp: nil, at: start)
        let model = await makeModel()
        let code = try #require(stored(github)).code(at: CodeFixtures.date).digits

        model.query = "GMAIL"
        #expect(model.rows.map(\.code?.displayName) == ["Google (me@gmail.com)"])
        #expect(model.selectedCode == stored(google))

        model.query = "github"
        #expect(model.rows.map { $0.entry?.text ?? $0.code?.displayName } == ["GitHub (octocat)", "github notes"])

        model.query = code
        #expect(model.rows.isEmpty)
        #expect(!model.showsEntries)
    }

    @Test func previewPinAndDeleteLeaveACodeAlone() async throws {
        let model = await makeModel()
        #expect(model.handleKey(.right, isCaretAtEnd: true) == .ignored)
        #expect(model.handleKey(.delete, isCaretAtEnd: true) == .ignored)
        #expect(model.handleKey(.pin, isCaretAtEnd: true) == .handled)
        #expect(model.handleKey(.undo, isCaretAtEnd: true) == .ignored)
        #expect(codes.accounts.count == 2)
        #expect(!model.preview.isOpen)
    }

    @Test func deletingTheEntryUnderTheCodesSelectsTheCodeAboveIt() async throws {
        history.record(text: "current", sourceApp: nil, at: start)
        let model = await makeModel()
        _ = model.handleKey(.down, isCaretAtEnd: true)
        _ = model.handleKey(.down, isCaretAtEnd: true)
        let entry = try #require(model.selectedEntry)

        model.delete(entry)

        #expect(model.selectedCode == stored(google))
    }

    @Test func aRemovedAccountLeavesTheList() async throws {
        let model = await makeModel()
        let github = try #require(stored(github))

        await codes.remove(id: github.id)

        #expect(model.rows.map(\.code?.displayName) == ["Google (me@gmail.com)"])
        #expect(model.selectedCode == stored(google))
    }

    /// A trackpad swipe of `distance` points to the left over the row of `account`, in one step.
    private func swipeLeft(_ distance: CGFloat, on account: CodeAccount, in model: HistoryWindowModel) {
        let row = HistoryRowItem.code(account)
        _ = model.swipeScrolled(RowSwipe.Scroll(phase: .began), on: row)
        _ = model.swipeScrolled(RowSwipe.Scroll(phase: .changed, deltaX: -distance), on: row)
        _ = model.swipeScrolled(RowSwipe.Scroll(phase: .ended), on: row)
    }

    @Test func aFullSwipeOnACodeOnlyOpensItsRowAndAClickClosesIt() async throws {
        let model = await makeModel()
        let github = try #require(stored(github))

        swipeLeft(RowSwipe.maximumOffset, on: github, in: model)

        #expect(codes.accounts.count == 2)
        #expect(model.swipe.swipedRowID == github.id)
        #expect(model.swipe.offset(of: github.id) == RowSwipe.actionsWidth(buttonCount: RowAction.codeOffers.count))
        #expect(model.closeSwipedRow())
        #expect(model.swipe.swipedRowID == nil)
    }

    @Test func removeAccountRemovesTheAccountWithItsSecretAndClosesTheRow() async throws {
        let model = await makeModel()
        let github = try #require(stored(github))
        swipeLeft(RowSwipe.holdThreshold + 1, on: github, in: model)

        await model.remove(github)

        #expect(model.swipe.swipedRowID == nil)
        #expect(codes.accounts.map(\.account) == [google])
        #expect(model.rows.map(\.code?.displayName) == ["Google (me@gmail.com)"])
        #expect(model.selectedCode == stored(google))
    }

    @Test func aModelWithoutCodesListsNoneAndOffersNoButton() {
        let model = HistoryWindowModel(history: history)
        #expect(!model.hasCodes)
        model.toggleCodes()
        #expect(model.codeRows.isEmpty)
        #expect(!model.showsEntries)
    }
}
