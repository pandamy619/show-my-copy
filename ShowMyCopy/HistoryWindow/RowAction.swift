/// What can be done to one row of the history window, an entry's or a code's. One list in one order for the row's
/// context menu, the buttons a swipe shows and the row's VoiceOver actions, so the three never drift apart.
enum RowAction: Hashable, Sendable {
    case showPreview
    case pin
    case unpin
    case delete
    /// Copies the account's code, like a click on its row.
    case copyCode
    /// Removes the account, with its secret, as the button in Settings → Codes does.
    case removeAccount

    /// An action a row offers, and whether it can be used now. A disabled one is shown dimmed and does nothing.
    struct Offer: Equatable, Sendable {
        let action: RowAction
        let isEnabled: Bool
    }

    /// The most actions one row offers. Swipe sizes are checked against it (`RowSwipe`).
    static let maximumCount = 3

    /// The actions the row offers, for an entry or a code.
    @MainActor
    static func offers(for row: HistoryRowItem) -> [Offer] {
        switch row {
        case .entry(let entry):
            offers(for: entry)
        case .code:
            codeOffers
        }
    }

    /// The actions the row of an account offers, every account the same: Copy Code, then Remove Account, last and
    /// red like Delete. Removing is not undone, so a full swipe never removes an account (`RowSwipe`).
    static let codeOffers = [Offer(action: .copyCode, isEnabled: true), Offer(action: .removeAccount, isEnabled: true)]

    /// The actions the row of `entry` offers, in order: Show Preview, except for a password, which is never
    /// previewed; Pin, dimmed for a password, which keeps its own expiry, or Unpin for a pinned entry; and Delete,
    /// last, for every entry, also the one on the clipboard. Every kind of content offers the same.
    @MainActor
    static func offers(for entry: ClipboardEntry) -> [Offer] {
        var offers: [Offer] = []
        if EntryPreviewModel.canPreview(entry) {
            offers.append(Offer(action: .showPreview, isEnabled: true))
        }
        if entry.isPinned {
            offers.append(Offer(action: .unpin, isEnabled: true))
        } else {
            offers.append(Offer(action: .pin, isEnabled: HistoryWindowModel.canPin(entry)))
        }
        offers.append(Offer(action: .delete, isEnabled: true))
        return offers
    }

    var isDestructive: Bool {
        self == .delete || self == .removeAccount
    }
}

extension HistoryWindowModel {
    /// Does what the row's menu item, swipe button or VoiceOver action `action` does to `entry`, and closes the
    /// swiped row. Pin shows the pin limit notice when it unpinned the oldest pinned entry (`togglePin`). Pin and Unpin
    /// only pin and only unpin: an entry pinned or unpinned meanwhile is left as it is. A code's actions do nothing
    /// to an entry.
    func perform(_ action: RowAction, on entry: ClipboardEntry) {
        swipe.close()
        switch action {
        case .showPreview:
            showPreview(of: entry)
        case .pin, .unpin:
            let isPinned = history.entries.first { $0.id == entry.id }?.isPinned
            if isPinned == (action == .unpin) {
                togglePin(entry)
            }
        case .delete:
            delete(entry)
        case .copyCode, .removeAccount:
            break
        }
    }

    /// Removes the account, with its secret, for Remove Account on its row, and closes the swiped row. The row
    /// leaves the list once the store has removed it. Copy Code is the view's: it copies like a click on the row.
    func remove(_ account: CodeAccount) async {
        swipe.close()
        await codes?.remove(id: account.id)
    }
}
