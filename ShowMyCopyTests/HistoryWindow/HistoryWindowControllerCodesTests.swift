import Foundation
import Testing

@testable import ShowMyCopy

/// Choosing a code in the history window: the copy, the close and the paste. And the codes shortcut, which shows and
/// hides the codes of the open window.
@MainActor
@Suite(.serialized, .oneWindowAtATime)
struct HistoryWindowControllerCodesTests {
    private let pasteboard = FakePasteboard()
    private let history = InMemoryHistoryStore()
    private let codes = CodeAccountStore(persistence: InMemoryCodeAccounts(), now: { CodeFixtures.date })
    private let monitor: ClipboardMonitor
    private let paster = EntryPasterSpy()

    @MainActor
    private final class CodeCopierSpy: CodeCopying {
        var copied: [CodeAccount] = []
        var fails = false
        var changeCount = 7

        func copy(_ account: CodeAccount) -> Int? {
            copied.append(account)
            return fails ? nil : changeCount
        }
    }

    init() {
        monitor = MonitorFactory.make(pasteboard: pasteboard, history: history)
    }

    private func makeController(copier: CodeCopierSpy) async -> HistoryWindowController {
        await codes.add([CodeFixtures.account()])
        let model = HistoryWindowModel(
            history: history, deleter: EntryDeleterSpy(history: history), codes: codes,
            pastesAfterChoosing: { true })
        model.showsCodes = true
        return HistoryWindowController(
            model: model,
            copier: EntryCopier(history: history, pasteboard: pasteboard, monitor: monitor),
            codeCopier: copier,
            paster: paster,
            monitor: monitor,
            onOpenSettings: { _ in }
        )
    }

    @Test func returnCopiesTheCodeClosesTheWindowAndPastes() async throws {
        let copier = CodeCopierSpy()
        let controller = await makeController(copier: copier)
        controller.show()
        defer { controller.hide() }
        let account = try #require(codes.accounts.first)
        // Opening the window hides the codes; the user shows them with the button next to the gear.
        #expect(!controller.model.showsCodes)
        controller.model.toggleCodes()

        #expect(controller.handleCommandKey(.return))

        #expect(copier.copied == [account])
        #expect(!controller.isVisible)
        #expect(paster.pastedChangeCounts == [7])
    }

    @Test func aFailedCopyLeavesTheWindowOpen() async throws {
        let copier = CodeCopierSpy()
        copier.fails = true
        let controller = await makeController(copier: copier)
        controller.show()
        defer { controller.hide() }

        controller.chooseCode(try #require(codes.accounts.first), pastes: true)

        #expect(controller.isVisible)
        #expect(paster.pastedChangeCounts.isEmpty)
    }

    // MARK: - The codes shortcut

    @Test func theCodesShortcutLeavesAClosedWindowClosed() async throws {
        let controller = await makeController(copier: CodeCopierSpy())
        defer { controller.hide() }
        controller.model.showsCodes = false

        controller.codesShortcutPressed()

        #expect(!controller.isVisible)
        #expect(!controller.model.showsCodes)
    }

    @Test func theCodesShortcutShowsAndHidesTheCodesOfTheOpenWindow() async throws {
        let controller = await makeController(copier: CodeCopierSpy())
        controller.show()
        defer { controller.hide() }
        #expect(!controller.model.showsCodes)

        controller.codesShortcutPressed()
        #expect(controller.isVisible)
        #expect(controller.model.showsCodes)
        #expect(controller.model.selectedCode == codes.accounts.first)

        controller.codesShortcutPressed()
        #expect(controller.isVisible)
        #expect(!controller.model.showsCodes)
    }

    @Test func returnRightAfterTheCodesShortcutCopiesTheFirstCode() async throws {
        let copier = CodeCopierSpy()
        let controller = await makeController(copier: copier)
        pasteboard.copy("an entry above which the codes slide in")
        monitor.poll()
        controller.show()
        defer { controller.hide() }

        controller.codesShortcutPressed()
        #expect(controller.handleCommandKey(.return))

        #expect(copier.copied == [try #require(codes.accounts.first)])
        #expect(!controller.isVisible)
    }

    @Test func withoutAccountsTheCodesShortcutDoesNothing() async throws {
        let controller = HistoryWindowController(
            model: HistoryWindowModel(
                history: history, deleter: EntryDeleterSpy(history: history), codes: codes,
                pastesAfterChoosing: { false }),
            copier: EntryCopier(history: history, pasteboard: pasteboard, monitor: monitor),
            codeCopier: CodeCopierSpy(), paster: paster, monitor: monitor, onOpenSettings: { _ in })
        controller.show()
        defer { controller.hide() }

        controller.codesShortcutPressed()

        #expect(controller.isVisible)
        #expect(!controller.model.showsCodes)
    }

    @Test func aWindowWithoutACodeCopierCopiesNothing() async throws {
        await codes.add([CodeFixtures.account()])
        let controller = HistoryWindowController(
            model: HistoryWindowModel(
                history: history, deleter: EntryDeleterSpy(history: history), codes: codes,
                pastesAfterChoosing: { false }),
            copier: EntryCopier(history: history, pasteboard: pasteboard, monitor: monitor),
            paster: paster, monitor: monitor, onOpenSettings: { _ in })
        controller.show()
        defer { controller.hide() }

        controller.chooseCode(try #require(codes.accounts.first), pastes: false)

        #expect(controller.isVisible)
        #expect(pasteboard.writtenTexts.isEmpty)
    }
}
