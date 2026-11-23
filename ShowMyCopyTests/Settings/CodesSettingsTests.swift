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

    // MARK: - Names

    private func settingsWithGitHub() async throws -> (CodesSettings, CodeAccount) {
        let settings = makeSettings()
        settings.draft = CodeFixtures.addressURL
        await settings.addDraft()
        return (settings, try #require(settings.accounts.first))
    }

    @Test func editingShowsTheNamesAndSavingRenamesTheAccount() async throws {
        let (settings, github) = try await settingsWithGitHub()

        settings.beginEditing(github)
        #expect(settings.isEditing(github))
        #expect(settings.editedIssuer == "GitHub")
        #expect(settings.editedName == "octocat")

        settings.editedIssuer = "Work"
        await settings.saveEditing()
        await settings.store.finishSaving()

        #expect(settings.editingID == nil)
        #expect(settings.accounts.map(\.displayName) == ["Work (octocat)"])
        #expect(settings.accounts.first?.id == github.id)
        #expect(persistence.saved.map(\.displayName) == ["Work (octocat)"])
    }

    @Test func cancelLeavesTheNamesAndAnUnnamedAccountCannotBeSaved() async throws {
        let (settings, github) = try await settingsWithGitHub()
        settings.beginEditing(github)
        settings.editedIssuer = " "
        settings.editedName = ""
        #expect(!settings.canSaveEditing)

        await settings.saveEditing()
        #expect(settings.isEditing(github))
        settings.cancelEditing()

        #expect(settings.editingID == nil)
        #expect(settings.accounts.map(\.displayName) == ["GitHub (octocat)"])
    }

    @Test func aRefusedRenameKeepsTheFieldsOpenAndSaysSo() async throws {
        let (settings, github) = try await settingsWithGitHub()
        await settings.store.add([CodeFixtures.account(issuer: "Work")])
        settings.beginEditing(github)
        settings.editedIssuer = "Work"

        await settings.saveEditing()

        #expect(settings.isEditing(github))
        #expect(settings.editRefused)
        #expect(settings.editedIssuer == "Work")
        settings.editedIssuer = "Home"
        await settings.saveEditing()
        #expect(!settings.editRefused)
        #expect(settings.editingID == nil)
        #expect(settings.accounts.map(\.displayName) == ["Home (octocat)", "Work (octocat)"])
    }

    @Test func removingTheEditedAccountClosesItsFields() async throws {
        let (settings, github) = try await settingsWithGitHub()
        settings.beginEditing(github)

        await settings.remove(github)

        #expect(settings.editingID == nil)
        #expect(settings.accounts.isEmpty)
    }

    @Test func theWarningFollowsTheStore() async {
        let store = CodeAccountStore(
            persistence: InMemoryCodeAccounts(loadResult: .damaged), now: { CodeFixtures.date })
        #expect(CodesSettingsPage.storageWarning(for: store) == nil)
        await store.load()
        #expect(CodesSettingsPage.storageWarning(for: store) != nil)
    }
}
