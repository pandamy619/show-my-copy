import Foundation

/// An account the user added, as the app keeps it: the account itself, an identity that survives edits to the list,
/// and when it was added, which breaks ties in the list.
struct CodeAccount: Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let account: OneTimeCodeAccount
    let addedAt: Date

    init(id: UUID = UUID(), account: OneTimeCodeAccount, addedAt: Date) {
        self.id = id
        self.account = account
        self.addedAt = addedAt
    }

    /// What the list shows: "Issuer (name)", sanitized like any text another app supplied, on one line.
    var displayName: String {
        let name = EntryPreview.text(account.displayName).split(whereSeparator: \.isNewline).joined(separator: " ")
        return name.isEmpty ? String(localized: "Unnamed account") : name
    }

    /// The code the account shows at `now`.
    func code(at now: Date) -> OneTimeCode {
        TOTP.code(for: account, at: now)
    }

    /// The lists are shown sorted by name, without regard to letter case; accounts with the same name in the order
    /// they were added.
    static func sorted(_ accounts: [CodeAccount]) -> [CodeAccount] {
        accounts.sorted { lhs, rhs in
            switch lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) {
            case .orderedAscending:
                true
            case .orderedDescending:
                false
            case .orderedSame:
                lhs.addedAt < rhs.addedAt || (lhs.addedAt == rhs.addedAt && lhs.id.uuidString < rhs.id.uuidString)
            }
        }
    }
}
