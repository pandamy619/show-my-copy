import Foundation
import Synchronization

@testable import ShowMyCopy

/// Keeps the saved accounts in memory and fails on demand, so the store's handling of what the disk says is tested
/// without a disk or a Keychain.
final class InMemoryCodeAccounts: CodeAccountsPersisting, Sendable {
    private struct State {
        var saved: [CodeAccount] = []
        var loadResult: CodeAccountsLoad?
        var saveError: CodeAccountsSaveError?
        var loadCount = 0
        var saveCount = 0
        var savedLists: [[CodeAccount]] = []
    }

    private let state: Mutex<State>

    /// Starts with `saved` on "disk". `loadResult` replaces what a load returns; nil returns the saved accounts.
    init(saved: [CodeAccount] = [], loadResult: CodeAccountsLoad? = nil) {
        state = Mutex(State(saved: saved, loadResult: loadResult))
    }

    /// The accounts on "disk" now.
    var saved: [CodeAccount] {
        state.withLock { $0.saved }
    }

    var loadCount: Int {
        state.withLock { $0.loadCount }
    }

    var saveCount: Int {
        state.withLock { $0.saveCount }
    }

    /// Every list that was saved, in order.
    var savedLists: [[CodeAccount]] {
        state.withLock { $0.savedLists }
    }

    /// What the next loads return instead of the saved accounts; nil to return them again.
    func setLoadResult(_ result: CodeAccountsLoad?) {
        state.withLock { $0.loadResult = result }
    }

    /// Makes every save fail with `error` until set to nil. The "disk" is left as it is.
    func setSaveError(_ error: CodeAccountsSaveError?) {
        state.withLock { $0.saveError = error }
    }

    func load() async -> CodeAccountsLoad {
        state.withLock { state in
            state.loadCount += 1
            return state.loadResult ?? .accounts(state.saved)
        }
    }

    func save(_ accounts: [CodeAccount]) async throws(CodeAccountsSaveError) {
        let error: CodeAccountsSaveError? = state.withLock { state in
            state.saveCount += 1
            if let error = state.saveError {
                return error
            }
            state.saved = accounts
            state.savedLists.append(accounts)
            return nil
        }
        if let error {
            throw error
        }
    }
}

/// Finds the QR payloads a test put in it, whatever the image data.
final class FakeQRCodeReader: QRCodeReading, Sendable {
    private let state: Mutex<(payloads: [String], readCount: Int)>

    init(payloads: [String] = []) {
        state = Mutex((payloads, 0))
    }

    var readCount: Int {
        state.withLock { $0.readCount }
    }

    func payloads(inImageData data: Data, typeIdentifier: String) async -> [String] {
        state.withLock { state in
            state.readCount += 1
            return state.payloads
        }
    }
}

extension AppServices.Codes {
    /// No saved accounts, and no QR codes in any image.
    static func fake(
        persistence: any CodeAccountsPersisting = InMemoryCodeAccounts(),
        qrReader: any QRCodeReading = FakeQRCodeReader()
    ) -> AppServices.Codes {
        AppServices.Codes(persistence: persistence, qrReader: qrReader)
    }
}
