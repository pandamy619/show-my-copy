import Foundation

/// How the container builds and loads the one-time codes (Settings → Codes, the Codes section of the history window).
extension AppContainer {
    /// The objects of one-time codes (`makeCodes`).
    struct CodeServices {
        let store: CodeAccountStore
        let settings: CodesSettings
        let copier: CodeCopier
    }

    /// One-time codes: the accounts, how a QR code on the clipboard adds some (Settings → Codes), and how the
    /// history window copies a code.
    static func makeCodes(
        store: any HistoryStore, services: AppServices, monitor: ClipboardMonitor
    ) -> CodeServices {
        let system = services.system
        let accounts = CodeAccountStore(persistence: services.codes.persistence, now: system.now)
        let importer = ClipboardCodeImporter(
            pasteboard: services.pasteboard, history: store, monitor: monitor, reader: services.codes.qrReader,
            store: accounts)
        let copier = CodeCopier(
            history: store, pasteboard: services.pasteboard, monitor: monitor, now: system.now, sleep: system.sleep)
        return CodeServices(
            store: accounts, settings: CodesSettings(store: accounts, importer: importer), copier: copier)
    }

    /// Loads the saved code accounts in the background. Their file is opened only when there is one, so a user
    /// without codes never sees a Keychain prompt for them.
    static func loadCodes(_ codes: CodeAccountStore?) {
        guard let codes else {
            return
        }
        Task {
            await codes.load()
        }
    }
}
