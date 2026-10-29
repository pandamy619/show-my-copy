import Foundation

/// What the history window lists, by section, top to bottom: the entry on the clipboard now, the pinned entries in
/// the order they were pinned, then the other entries, newest first. A new copy goes on the clipboard row, so it
/// never moves above the pinned entries, and the arrow keys walk the sections in this order (`rows`).
///
/// A pinned entry on the clipboard stays in its place among the pinned entries: they keep their order while they
/// are used. Then no entry is in the clipboard row.
struct HistorySections: Equatable, Sendable {
    static let empty = HistorySections(current: nil, pinned: [], history: [])

    let current: ClipboardEntry?
    let pinned: [ClipboardEntry]
    let history: [ClipboardEntry]

    /// Every listed entry, in the order the window shows them.
    var rows: [ClipboardEntry] {
        (current.map { [$0] } ?? []) + pinned + history
    }

    var isEmpty: Bool {
        current == nil && pinned.isEmpty && history.isEmpty
    }

    /// Where the entries of each section are in the history's entries. Positions rather than copies, so a cache of
    /// them does not keep an entry alive that the history removed, such as an expired password.
    struct Positions: Equatable, Sendable {
        let current: Int?
        let pinned: [Int]
        let history: [Int]

        /// Sorts the `listed` positions of `entries`, which are newest first as the history keeps them. A pinned
        /// entry's date is when it was pinned, so the pinned ones are listed oldest first.
        init(of entries: [ClipboardEntry], listed: [Int], currentEntryID: ClipboardEntry.ID?) {
            var pinned: [Int] = []
            var history: [Int] = []
            var current: Int?
            for index in listed {
                let entry = entries[index]
                if entry.isPinned {
                    pinned.append(index)
                } else if entry.id == currentEntryID {
                    current = index
                } else {
                    history.append(index)
                }
            }
            self.current = current
            self.pinned = pinned.reversed()
            self.history = history
        }

        /// The sections of `entries`, which must be the entries these positions were found in.
        func sections(in entries: [ClipboardEntry]) -> HistorySections {
            HistorySections(
                current: current.map { entries[$0] },
                pinned: pinned.map { entries[$0] },
                history: history.map { entries[$0] })
        }
    }
}
