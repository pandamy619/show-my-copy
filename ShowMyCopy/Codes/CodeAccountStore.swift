import Foundation
import Observation

/// The accounts the user added, in memory, and what keeping them on disk found (`CodeAccountsPersisting`).
///
/// Accounts are added and removed at once in memory and then saved, the whole list in one write. Only a list this
/// session loaded is ever saved: when the saved file could not be read (no key, damaged, newer), accounts added
/// now stay in memory until the app quits, and the file is left as it is, so nothing saved is lost to a session that
/// could not see it. The Keychain can be locked at launch; `load()` is called again when the user is back.
@MainActor
@Observable
final class CodeAccountStore {
    /// Whether the saved accounts are in hand.
    enum Availability: Equatable, Sendable {
        /// Loading, or not started yet.
        case loading
        /// The saved accounts are loaded; changes are saved.
        case ready
        /// Not loaded, for this reason. Changes are kept in memory only.
        case unavailable(CodeAccountsLoad)
    }

    struct AddResult: Equatable, Sendable {
        var added: Int
        /// Accounts that were in the list already (same issuer, name and secret).
        var duplicates: Int
    }

    /// Sorted by name (`CodeAccount.sorted`).
    private(set) var accounts: [CodeAccount] = []
    private(set) var availability: Availability = .loading
    /// Whether the last save failed. The accounts are kept in memory; the next change tries again.
    private(set) var lastSaveFailed = false

    @ObservationIgnored private let persistence: any CodeAccountsPersisting
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var loading: Task<Void, Never>?
    /// Saves run one after the other, each with the list as it was when the change was made.
    @ObservationIgnored private var saving: Task<Void, Never>?

    init(persistence: any CodeAccountsPersisting, now: @escaping @MainActor () -> Date) {
        self.persistence = persistence
        self.now = now
    }

    /// Whether the window has anything to list.
    var isEmpty: Bool {
        accounts.isEmpty
    }

    /// Loads the saved accounts, off the main actor. Called at launch, before every change, and again when the user
    /// is back at the unlocked Mac, in case the Keychain was locked. Does nothing while the accounts are loaded or
    /// being loaded, or when a load found a reason that will not change this session: only a locked Keychain is
    /// asked again.
    func load() async {
        if let loading {
            await loading.value
            return
        }
        switch availability {
        case .loading, .unavailable(.keyLockedOut):
            break
        case .ready, .unavailable:
            return
        }
        let task = Task { [persistence] in
            let loaded = await persistence.load()
            apply(loaded)
        }
        loading = task
        await task.value
        loading = nil
    }

    private func apply(_ loaded: CodeAccountsLoad) {
        switch loaded {
        case .accounts(let saved):
            // Accounts added while the file was unavailable are kept; a saved copy of one of them counts once.
            let added = accounts.filter { pending in !saved.contains { $0.account == pending.account } }
            accounts = CodeAccount.sorted(saved + added)
            availability = .ready
            if !added.isEmpty {
                save()
            }
        case .keyLockedOut, .keyUnavailable, .damaged, .newerFormat, .unreadable:
            availability = .unavailable(loaded)
        }
    }

    /// Adds the accounts that are not in the list yet and saves the list. Waits for a load in progress first, so a
    /// saved list is never written over by one that does not hold it.
    @discardableResult
    func add(_ new: [OneTimeCodeAccount]) async -> AddResult {
        await load()
        var result = AddResult(added: 0, duplicates: 0)
        var known = Set(accounts.map(\.account))
        var added: [CodeAccount] = []
        let date = now()
        for account in new {
            if known.insert(account).inserted {
                added.append(CodeAccount(account: account, addedAt: date))
                result.added += 1
            } else {
                result.duplicates += 1
            }
        }
        guard !added.isEmpty else {
            return result
        }
        accounts = CodeAccount.sorted(accounts + added)
        save()
        return result
    }

    /// Removes the account and saves the list without it. The secret goes with it.
    func remove(id: CodeAccount.ID) async {
        await load()
        guard accounts.contains(where: { $0.id == id }) else {
            return
        }
        accounts.removeAll { $0.id == id }
        save()
    }

    /// Saves the list as it is now, after the save before it, when the saved list is in hand.
    private func save() {
        guard availability == .ready else {
            return
        }
        let snapshot = accounts
        let previous = saving
        saving = Task { [persistence] in
            await previous?.value
            do {
                try await persistence.save(snapshot)
                lastSaveFailed = false
            } catch {
                AppLogger.security.error("Code accounts not saved: \(String(describing: error), privacy: .public)")
                lastSaveFailed = true
            }
        }
    }

    /// Waits for the saves made so far. Tests call it; the app lets them finish in the background.
    func finishSaving() async {
        await saving?.value
    }
}
