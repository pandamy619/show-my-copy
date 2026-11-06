import Foundation
import Testing

@testable import ShowMyCopy

/// Return and ⌥Return in the history window with Settings → General → Paste after choosing an entry off and on.
@MainActor
@Suite(.serialized)
struct HistoryWindowPasteTests {
    private let pasteboard = FakePasteboard()
    private let history = InMemoryHistoryStore()
    private let monitor: ClipboardMonitor
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// What Settings say; tests flip it as the user would.
    @MainActor
    private final class Setting {
        var isOn = false
    }

    init() {
        monitor = MonitorFactory.make(pasteboard: pasteboard, history: history)
    }

    private func makeModel(_ setting: Setting) -> HistoryWindowModel {
        history.record(text: "older", sourceApp: nil, at: start)
        history.record(text: "newer", sourceApp: nil, at: start + 1)
        return HistoryWindowModel(history: history, pastesAfterChoosing: { setting.isOn })
    }

    private func makeController(paster: EntryPasterSpy) -> HistoryWindowController {
        HistoryWindowController(
            model: HistoryWindowModel(history: history),
            copier: EntryCopier(history: history, pasteboard: pasteboard, monitor: monitor),
            paster: paster,
            monitor: monitor,
            onOpenSettings: { _ in }
        )
    }

    // MARK: - Keys

    @Test func returnOnlyCopiesWhilePastingIsOff() throws {
        let model = makeModel(Setting())
        let selected = try #require(model.selectedEntry)

        #expect(model.handleKey(.return, isCaretAtEnd: true) == .choose(selected, pastes: false))
        #expect(model.handleKey(.optionReturn, isCaretAtEnd: true) == .choose(selected, pastes: true))
    }

    @Test func returnPastesWhilePastingIsOn() throws {
        let setting = Setting()
        setting.isOn = true
        let model = makeModel(setting)
        let selected = try #require(model.selectedEntry)

        #expect(model.handleKey(.return, isCaretAtEnd: true) == .choose(selected, pastes: true))
        #expect(model.handleKey(.optionReturn, isCaretAtEnd: true) == .choose(selected, pastes: false))
    }

    @Test func theSettingIsReadOnEveryKeyPress() throws {
        let setting = Setting()
        let model = makeModel(setting)
        let selected = try #require(model.selectedEntry)
        #expect(model.handleKey(.return, isCaretAtEnd: true) == .choose(selected, pastes: false))

        // Turned on in Settings while the window was open.
        setting.isOn = true

        #expect(model.handleKey(.return, isCaretAtEnd: true) == .choose(selected, pastes: true))
        #expect(model.choosingPastes(isAlternate: false))
        #expect(!model.choosingPastes(isAlternate: true))
    }

    @Test func returnAndOptionReturnWithNothingListedDoNothing() {
        let setting = Setting()
        setting.isOn = true
        let model = HistoryWindowModel(history: InMemoryHistoryStore(), pastesAfterChoosing: { setting.isOn })

        #expect(model.handleKey(.return, isCaretAtEnd: true) == .handled)
        #expect(model.handleKey(.optionReturn, isCaretAtEnd: true) == .handled)
    }

    /// A password is chosen like any other entry, and choosing it never reveals it.
    @Test func choosingAPasswordToPasteDoesNotRevealIt() throws {
        let setting = Setting()
        setting.isOn = true
        let model = makeModel(setting)
        history.record(text: "hunter2", sourceApp: nil, at: start + 2, concealed: true, expiresAt: .distantFuture)
        let password = try #require(model.selectedEntry)
        #expect(password.isConcealed)

        #expect(model.handleKey(.return, isCaretAtEnd: true) == .choose(password, pastes: true))
        #expect(!model.isRevealed(password.id))
    }

    // MARK: - Hint

    @Test func pasteHintIsShownInTheWindowOpeningNowOnly() {
        let model = makeModel(Setting())
        model.pasteHint = .noAccess

        model.prepareForPresentation()

        #expect(model.pasteHint == nil)
    }

    @Test func openingTheWindowTellsAFallbackOnceAndClosingHidesIt() {
        let paster = EntryPasterSpy()
        let controller = makeController(paster: paster)
        paster.fallbackHint = .noAccess

        controller.show()
        #expect(controller.model.pasteHint == .noAccess)

        controller.hide()
        #expect(controller.model.pasteHint == nil)

        controller.show()
        #expect(controller.model.pasteHint == nil)
    }

    // MARK: - Choosing

    @Test func choosingToPasteCopiesClosesThenPastesWhatWasCopied() throws {
        pasteboard.copy("older")
        monitor.poll()
        pasteboard.copy("newer")
        let paster = EntryPasterSpy()
        let controller = makeController(paster: paster)
        controller.show()
        let older = try #require(controller.model.items.last)

        controller.choose(older, pastes: true)

        #expect(pasteboard.writtenTexts == ["older"])
        #expect(!controller.isVisible)
        // The paste is handed the change count of the copy, so it can tell whether the clipboard changed since.
        #expect(paster.pastedChangeCounts == [pasteboard.changeCount])
    }

    @Test func choosingToCopyDoesNotPaste() throws {
        pasteboard.copy("older")
        monitor.poll()
        let paster = EntryPasterSpy()
        let controller = makeController(paster: paster)
        controller.show()
        let older = try #require(controller.model.items.first)

        controller.choose(older, pastes: false)

        #expect(pasteboard.writtenTexts == ["older"])
        #expect(!controller.isVisible)
        #expect(paster.pastedChangeCounts.isEmpty)
    }

    @Test func aFailedCopyIsNotPastedAndKeepsTheWindowOpen() throws {
        pasteboard.copy("older")
        monitor.poll()
        pasteboard.copy("newer")
        let paster = EntryPasterSpy()
        let controller = makeController(paster: paster)
        controller.show()
        let older = try #require(controller.model.items.last)
        pasteboard.writeFails = true

        controller.choose(older, pastes: true)

        #expect(controller.isVisible)
        #expect(paster.pastedChangeCounts.isEmpty)
    }

    @Test func aReturnAfterTheWindowClosedNeitherCopiesNorPastes() throws {
        pasteboard.copy("older")
        monitor.poll()
        let paster = EntryPasterSpy()
        let controller = makeController(paster: paster)
        let older = try #require(history.entries.first)

        controller.choose(older, pastes: true)

        #expect(pasteboard.writtenTexts.isEmpty)
        #expect(paster.pastedChangeCounts.isEmpty)
    }

    /// The whole way, with the app's copier and paster: a password goes onto the clipboard marked as concealed and
    /// is pasted as it is, and nothing about it is read back.
    @Test func aPasswordIsPastedMarkedAsConcealed() async throws {
        try await ContainerFactory.withDefaults { defaults in
            let keystrokes = FakePasteKeystrokes(isAllowed: true)
            let settings = PasteSettings.make(defaults: defaults, keystrokes: keystrokes)
            let textEdit = SourceApp(bundleIdentifier: "com.apple.TextEdit", name: "TextEdit")
            let paster = EntryPaster(
                pasteboard: pasteboard, keystrokes: keystrokes, settings: settings, frontmostApp: { textEdit },
                ownBundleIdentifier: "com.example.ShowMyCopy", sleep: { _ in })
            let copier = EntryCopier(history: history, pasteboard: pasteboard, monitor: monitor)
            history.record(text: "hunter2", sourceApp: nil, at: start, concealed: true, expiresAt: .distantFuture)
            let password = try #require(history.entries.first)

            let changeCount = try #require(copier.copy(password))
            let outcome = await paster.paste(copiedAt: changeCount).value

            #expect(outcome == .pasted)
            #expect(pasteboard.writtenConcealed == [true])
            #expect(keystrokes.postCount == 1)
        }
    }
}
