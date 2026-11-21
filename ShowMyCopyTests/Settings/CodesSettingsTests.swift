import Foundation
import Testing

@testable import ShowMyCopy

@MainActor
struct CodesSettingsTests {
    private let pasteboard = FakePasteboard()
    private let history = InMemoryHistoryStore()
    private let persistence = InMemoryCodeAccounts()

    private func makeSettings(payloads: [String] = []) -> CodesSettings {
        let store = CodeAccountStore(persistence: persistence, now: { CodeFixtures.date })
        let monitor = MonitorFactory.make(pasteboard: pasteboard, history: history)
        let importer = ClipboardCodeImporter(
            pasteboard: pasteboard, history: history, monitor: monitor, reader: FakeQRCodeReader(payloads: payloads),
            store: store)
        return CodesSettings(store: store, importer: importer)
    }

    @Test func addsWhatWasPastedAndClearsTheFields() async {
        let settings = makeSettings()
        settings.draft = CodeFixtures.addressURL
        settings.draftIssuer = "ignored"

        await settings.addDraft()
        await settings.store.finishSaving()

        #expect(settings.accounts.map(\.displayName) == ["GitHub (octocat)"])
        #expect(settings.draft.isEmpty)
        #expect(settings.draftIssuer.isEmpty)
        guard case .imported(let summary)? = settings.note else {
            Issue.record("Expected an import note")
            return
        }
        #expect(summary.added == 1)
        #expect(persistence.saved.count == 1)
    }

    @Test func aKeyNeedsTheNamesAndTheFieldsAreKeptOnFailure() async {
        let settings = makeSettings()
        settings.draft = "JBSWY3DPEHPK3PXP"

        await settings.addDraft()

        #expect(settings.note == .failed(.keyNeedsName))
        #expect(settings.draft == "JBSWY3DPEHPK3PXP")
        settings.draftIssuer = "GitHub"
        await settings.addDraft()
        #expect(settings.accounts.map(\.displayName) == ["GitHub"])
    }

    @Test func readingTheClipboardReportsWhatItFound() async {
        let settings = makeSettings(payloads: [CodeFixtures.addressURL])
        pasteboard.copy("text")
        await settings.importFromClipboard()
        #expect(settings.note == .noImage)

        pasteboard.copyImage()
        await settings.importFromClipboard()
        guard case .imported(let summary)? = settings.note else {
            Issue.record("Expected an import note")
            return
        }
        #expect(summary.added == 1)
        #expect(settings.accounts.count == 1)
    }

    @Test func removingAnAccountClearsTheNote() async throws {
        let settings = makeSettings()
        settings.draft = CodeFixtures.addressURL
        await settings.addDraft()
        #expect(settings.note != nil)

        await settings.remove(try #require(settings.accounts.first))

        #expect(settings.accounts.isEmpty)
        #expect(settings.note == nil)
    }

    @Test func theWarningFollowsTheStore() async {
        let store = CodeAccountStore(
            persistence: InMemoryCodeAccounts(loadResult: .damaged), now: { CodeFixtures.date })
        #expect(CodesSettingsPage.storageWarning(for: store) == nil)
        await store.load()
        #expect(CodesSettingsPage.storageWarning(for: store) != nil)
    }
}
