import Foundation
import Observation

/// Settings → Codes: the accounts whose codes the history window shows, and the ways to add them: pasting an
/// address or a key, or reading the QR code from an image on the clipboard.
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
        await store.remove(id: account.id)
    }
}
