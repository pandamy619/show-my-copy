import Foundation
import Observation

/// Settings → Codes: the accounts whose codes the history window shows, the ways to add them: pasting an address or
/// a key, or reading the QR code from an image on the clipboard, and the names an account is listed by.
@MainActor
@Observable
final class CodesSettings {
    /// What the last add or import did, shown under the buttons until the next one.
    enum Note: Equatable, Sendable {
        case imported(CodeImportSummary)
        case failed(CodeImport.Failure)
        case noImage
        case noQRCode
        case notAnAccount(CodeImport.Failure)
    }

    let store: CodeAccountStore
    @ObservationIgnored private let importer: ClipboardCodeImporter

    /// The address, addresses or key the user pasted.
    var draft = ""
    /// The service and the account, used when `draft` is a bare key.
    var draftIssuer = ""
    var draftName = ""
    private(set) var note: Note?
    /// Whether an add or import is running, so the buttons run one at a time.
    private(set) var isBusy = false

    /// The account whose names are being edited in its row, with the service and account as typed so far. Nil
    /// when no row is. Only one row at a time.
    private(set) var editingID: CodeAccount.ID?
    var editedIssuer = ""
    var editedName = ""
    /// Whether the last save of edited names was refused: another account has these names and this secret.
    private(set) var editRefused = false

    init(store: CodeAccountStore, importer: ClipboardCodeImporter) {
        self.store = store
        self.importer = importer
    }

    var accounts: [CodeAccount] {
        store.accounts
    }

    /// Adds what `draft` holds. On success the fields are cleared.
    func addDraft() async {
        guard !isBusy else {
            return
        }
        isBusy = true
        defer { isBusy = false }
        let outcome: CodeImport.Outcome
        do {
            outcome = try CodeImport.parse(draft, issuer: draftIssuer, name: draftName)
        } catch {
            note = .failed(error)
            return
        }
        let result = await store.add(outcome.accounts)
        note = .imported(CodeImportSummary(result: result, outcome: outcome))
        draft = ""
        draftIssuer = ""
        draftName = ""
    }

    /// Reads the QR code in the image on the clipboard (`ClipboardCodeImporter`).
    func importFromClipboard() async {
        guard !isBusy else {
            return
        }
        isBusy = true
        defer { isBusy = false }
        switch await importer.importFromClipboardImage() {
        case .noImage:
            note = .noImage
        case .noQRCode:
            note = .noQRCode
        case .notAnAccount(let failure):
            note = .notAnAccount(failure)
        case .imported(let summary):
            note = .imported(summary)
        }
    }

    func remove(_ account: CodeAccount) async {
        note = nil
        if editingID == account.id {
            cancelEditing()
        }
        await store.remove(id: account.id)
    }

    // MARK: - Names

    /// Whether the row of `account` shows the fields instead of its name.
    func isEditing(_ account: CodeAccount) -> Bool {
        editingID == account.id
    }

    /// Shows the fields in the row of `account`, filled with its names; the row edited before goes back to its name.
    func beginEditing(_ account: CodeAccount) {
        editingID = account.id
        editedIssuer = account.account.issuer
        editedName = account.account.name
        editRefused = false
    }

    /// Hides the fields without changing anything.
    func cancelEditing() {
        editingID = nil
        editedIssuer = ""
        editedName = ""
        editRefused = false
    }

    /// Whether Save does anything: one of the names is typed, so the account is not left unnamed.
    var canSaveEditing: Bool {
        !(editedIssuer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && editedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Gives the account the typed names and hides the fields. They stay, with a note, when the store refused:
    /// another account has the same names and secret.
    func saveEditing() async {
        guard let editingID, canSaveEditing else {
            return
        }
        if await store.rename(id: editingID, issuer: editedIssuer, name: editedName) {
            cancelEditing()
        } else {
            editRefused = true
        }
    }
}
