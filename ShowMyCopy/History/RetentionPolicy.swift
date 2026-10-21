/// How much history is kept. The single place that knows the allowed limits.
struct RetentionPolicy: Equatable, Sendable {
    static let entryLimitRange = 10...1000
    static let defaultEntryLimit = 50
    static let `default` = RetentionPolicy()

    /// The most entries kept. Always within `entryLimitRange`.
    let entryLimit: Int

    init(entryLimit: Int = RetentionPolicy.defaultEntryLimit) {
        self.entryLimit = Self.clamped(entryLimit)
    }

    /// The same policy with another entry limit.
    func withEntryLimit(_ newLimit: Int) -> RetentionPolicy {
        RetentionPolicy(entryLimit: newLimit)
    }

    /// `value` moved into `entryLimitRange`.
    static func clamped(_ value: Int) -> Int {
        min(max(value, entryLimitRange.lowerBound), entryLimitRange.upperBound)
    }

    /// The entries the policy keeps, in their order. `entries` are newest first, so the oldest are removed.
    func kept(_ entries: [ClipboardEntry]) -> [ClipboardEntry] {
        Array(entries.prefix(entryLimit))
    }

    /// How many of `entries` the policy removes.
    func removedCount(from entries: [ClipboardEntry]) -> Int {
        entries.count - kept(entries).count
    }
}
