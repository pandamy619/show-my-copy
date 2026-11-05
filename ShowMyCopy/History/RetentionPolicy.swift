import Foundation

/// How much history is kept. The single place that knows the allowed limits.
struct RetentionPolicy: Equatable, Sendable {
    static let entryLimitRange = 10...1000
    static let defaultEntryLimit = 50
    static let `default` = RetentionPolicy()

    /// The most entries kept. Always within `entryLimitRange`.
    let entryLimit: Int
    /// The most bytes of content kept (the sum of `ClipboardEntry.byteSize`, which for an image is its data and
    /// thumbnail in the blob store), or nil for no size limit.
    let byteLimit: Int?
    /// How long an entry is kept after it was last copied (`ClipboardEntry.date`), or nil for no age limit. Never
    /// negative.
    let maxAge: Duration?

    init(entryLimit: Int = RetentionPolicy.defaultEntryLimit, byteLimit: Int? = nil, maxAge: Duration? = nil) {
        self.entryLimit = Self.clamped(entryLimit)
        self.byteLimit = byteLimit.map { max($0, 0) }
        self.maxAge = maxAge.map { max($0, .zero) }
    }

    /// The same policy with another entry limit.
    func withEntryLimit(_ newLimit: Int) -> RetentionPolicy {
        RetentionPolicy(entryLimit: newLimit, byteLimit: byteLimit, maxAge: maxAge)
    }

    /// The same policy with another byte limit, or none.
    func withByteLimit(_ newLimit: Int?) -> RetentionPolicy {
        RetentionPolicy(entryLimit: entryLimit, byteLimit: newLimit, maxAge: maxAge)
    }

    /// The same policy with another age limit, or none.
    func withMaxAge(_ newMaxAge: Duration?) -> RetentionPolicy {
        RetentionPolicy(entryLimit: entryLimit, byteLimit: byteLimit, maxAge: newMaxAge)
    }

    /// `value` moved into `entryLimitRange`.
    static func clamped(_ value: Int) -> Int {
        min(max(value, entryLimitRange.lowerBound), entryLimitRange.upperBound)
    }

    /// Whether `entry` was last copied `maxAge` or longer before `now`. A pinned entry never is.
    func isPastMaxAge(_ entry: ClipboardEntry, at now: Date) -> Bool {
        guard let maxAge, !entry.isPinned else {
            return false
        }
        return entry.date.addingTimeInterval(maxAge.timeInterval) <= now
    }

    /// The entries the policy keeps at `now`, in their order. `entries` are newest first, so the oldest are removed:
    /// once an entry does not fit, no older entry is kept either, even a smaller one. Entries past the age limit
    /// are removed and do not count toward the other limits.
    ///
    /// Pinned entries are never removed and do not count toward the limits, so pinning cannot crowd out new copies.
    /// An entry larger than the byte limit is not kept at all, so callers should not record one.
    func kept(_ entries: [ClipboardEntry], at now: Date) -> [ClipboardEntry] {
        var unpinnedCount = 0
        var unpinnedBytes = 0
        var isFull = false
        return entries.filter { entry in
            if entry.isPinned {
                return true
            }
            guard !isFull, !isPastMaxAge(entry, at: now) else {
                return false
            }
            unpinnedCount += 1
            unpinnedBytes += entry.byteSize
            if unpinnedCount > entryLimit || unpinnedBytes > (byteLimit ?? .max) {
                isFull = true
                return false
            }
            return true
        }
    }

    /// How many of `entries` the policy removes at `now`.
    func removedCount(from entries: [ClipboardEntry], at now: Date) -> Int {
        entries.count - kept(entries, at: now).count
    }
}

// MARK: - Pinned entries

extension RetentionPolicy {
    /// The most entries that are pinned at once. Pinned entries do not count toward the other limits, so this one
    /// bounds what they keep: up to 50 copies of the largest content allowed. Pinning one more unpins the oldest.
    static let maximumPinned = 50

    /// How far apart entries unpinned together are dated, so they keep their order after a relaunch too.
    private static let unpinnedSpacing: TimeInterval = 0.001

    /// `entries` with at most `maximumPinned` pinned. The oldest pinned entries over the limit (pinned first, by
    /// their date) are unpinned as the user unpins an entry at `date`: put at the top of the history as if just
    /// copied, the newest pinned of them first, so the age limit does not remove them at once and the other limits
    /// count them again. `keeping`, the entry the user just pinned, is never one of them, even when the clock was
    /// set back since the other pins. `entries` are newest first, as the history keeps them; with no more than
    /// `maximumPinned` pinned they are returned as they are.
    static func limitingPins(
        _ entries: [ClipboardEntry],
        at date: Date,
        keeping kept: ClipboardEntry.ID? = nil
    ) -> [ClipboardEntry] {
        let pinnedCount = entries.count(where: \.isPinned)
        guard pinnedCount > maximumPinned else {
            return entries
        }
        let oldest = entries.filter { $0.isPinned && $0.id != kept }.sorted { $0.date > $1.date }
            .suffix(pinnedCount - maximumPinned)
        let unpinnedIDs = Set(oldest.map(\.id))
        var limited = entries.filter { !unpinnedIDs.contains($0.id) }
        for (offset, entry) in oldest.enumerated() {
            var unpinned = entry
            unpinned.isPinned = false
            unpinned.date = date - Double(offset) * unpinnedSpacing
            limited.insert(unpinned, at: limited.firstIndex { $0.date <= unpinned.date } ?? limited.endIndex)
        }
        return limited
    }
}

extension Duration {
    /// The duration in seconds, for date arithmetic.
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
