/// How much history is kept. The single place that knows the allowed limits.
struct RetentionPolicy: Equatable, Sendable {
    static let entryLimitRange = 10...1000
    static let defaultEntryLimit = 50
    static let `default` = RetentionPolicy()

    /// The most entries kept. Always within `entryLimitRange`.
    let entryLimit: Int
    /// The most bytes of content kept (the sum of `ClipboardEntry.byteSize`), or nil for no size limit.
    /// Nothing sets it yet; it is there for a disk limit once the history is saved.
    let byteLimit: Int?

    init(entryLimit: Int = RetentionPolicy.defaultEntryLimit, byteLimit: Int? = nil) {
        self.entryLimit = Self.clamped(entryLimit)
        self.byteLimit = byteLimit.map { max($0, 0) }
    }

    /// The same policy with another entry limit.
    func withEntryLimit(_ newLimit: Int) -> RetentionPolicy {
        RetentionPolicy(entryLimit: newLimit, byteLimit: byteLimit)
    }

    /// The same policy with another byte limit, or none.
    func withByteLimit(_ newLimit: Int?) -> RetentionPolicy {
        RetentionPolicy(entryLimit: entryLimit, byteLimit: newLimit)
    }

    /// `value` moved into `entryLimitRange`.
    static func clamped(_ value: Int) -> Int {
        min(max(value, entryLimitRange.lowerBound), entryLimitRange.upperBound)
    }

    /// The entries the policy keeps, in their order. `entries` are newest first, so the oldest are removed: once an
    /// entry does not fit, no older entry is kept either, even a smaller one.
    ///
    /// Pinned entries are never removed and do not count toward the limits, so pinning cannot crowd out new copies.
    /// An entry larger than the byte limit is not kept at all, so callers should not record one.
    func kept(_ entries: [ClipboardEntry]) -> [ClipboardEntry] {
        var unpinnedCount = 0
        var unpinnedBytes = 0
        var isFull = false
        return entries.filter { entry in
            if entry.isPinned {
                return true
            }
            guard !isFull else {
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

    /// How many of `entries` the policy removes.
    func removedCount(from entries: [ClipboardEntry]) -> Int {
        entries.count - kept(entries).count
    }
}
