import Foundation

@testable import ShowMyCopy

/// Deletes from the history only, for window tests that do not look at the pasteboard. Remembers what it was asked.
@MainActor
final class EntryDeleterSpy: EntryDeleting {
    let history: any HistoryStore
    private(set) var deletedIDs: [ClipboardEntry.ID] = []
    private(set) var finishCount = 0
    private var deleted: ClipboardEntry?

    init(history: any HistoryStore) {
        self.history = history
    }

    var canUndoDelete: Bool {
        deleted != nil
    }

    func delete(_ id: ClipboardEntry.ID) {
        deletedIDs.append(id)
        deleted = history.entries.first { $0.id == id }
        history.remove(id: id)
    }

    func undoDelete() -> ClipboardEntry.ID? {
        guard let deleted else {
            return nil
        }
        self.deleted = nil
        history.restore([deleted])
        return deleted.id
    }

    func finishDeleting() {
        finishCount += 1
        deleted = nil
    }
}

extension HistoryWindowModel {
    /// A model whose deletions only remove entries from `history`.
    convenience init(history: any HistoryStore, previews: PreviewServices = PreviewServices()) {
        self.init(history: history, deleter: EntryDeleterSpy(history: history), previews: previews)
    }
}
