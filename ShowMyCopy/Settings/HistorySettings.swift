import Foundation
import Observation

/// The result of asking for a new history limit, before it is applied.
struct LimitChange<Limit: Equatable & Sendable>: Equatable, Sendable {
    /// The requested limit, moved into the allowed values.
    let limit: Limit
    /// How many of the oldest entries the new limit would delete.
    let removedCount: Int
    /// The total `byteSize` of those entries.
    let freedBytes: Int

    /// True when applying the limit deletes entries, so the user should confirm first.
    var needsConfirmation: Bool { removedCount > 0 }
}

/// The size limits offered in Settings. Decimal units, as Finder counts file sizes.
///
/// No limit is the default while the history holds only text: a thousand entries of text rarely reach even a few
/// megabytes, so a size limit would never apply and only raise questions. Once images and files are kept, a size
/// limit becomes the one that matters and the default can change; a saved choice, including No limit, stays.
enum HistorySizeLimit: Int, CaseIterable, Identifiable, Sendable {
    case noLimit = 0
    case megabytes100 = 100_000_000
    case megabytes500 = 500_000_000
    case gigabyte1 = 1_000_000_000

    static let `default` = HistorySizeLimit.noLimit

    var id: Int { rawValue }

    /// The byte limit for `RetentionPolicy`, or nil for no limit.
    var byteLimit: Int? {
        self == .noLimit ? nil : rawValue
    }

    /// The smallest option that allows `byteLimit` bytes, or the largest option when none does: a value the
    /// options do not offer keeps at least as much history as it allowed, up to the largest option, as the entry
    /// limit is clamped to its range.
    init(byteLimit: Int?) {
        guard let byteLimit else {
            self = .noLimit
            return
        }
        let limited = Self.allCases.filter { $0 != .noLimit }
        self = limited.first { $0.rawValue >= byteLimit } ?? .gigabyte1
    }
}

/// Stores the history limits in UserDefaults and applies them to the clipboard history.
@MainActor
@Observable
final class HistorySettings {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let history: any HistoryStore

    /// Leaves `history` as it is. Call `applyStoredLimit()` when the app starts, before the first entry is
    /// recorded. Creating the settings does not change the history, so the app decides when that happens.
    init(history: any HistoryStore, defaults: UserDefaults = .standard) {
        self.history = history
        self.defaults = defaults
    }

    /// The limit in effect. The history is the single source of truth.
    var limit: Int { history.limit }

    /// The size limit in effect, as one of the options.
    var sizeLimit: HistorySizeLimit { HistorySizeLimit(byteLimit: history.retention.byteLimit) }

    /// The saved limit, or the default when nothing valid is saved. Always within `RetentionPolicy.entryLimitRange`.
    nonisolated static func storedLimit(in defaults: UserDefaults) -> Int {
        guard let value = defaults.object(forKey: SettingsKey.historyLimit) as? Int else {
            return RetentionPolicy.defaultEntryLimit
        }
        return RetentionPolicy.clamped(value)
    }

    /// The saved size limit, or the default when nothing valid is saved. 0 is No limit, a negative or non-number
    /// value is ignored and other sizes are moved to an option.
    nonisolated static func storedSizeLimit(in defaults: UserDefaults) -> HistorySizeLimit {
        guard let value = defaults.object(forKey: SettingsKey.historyByteLimit) as? Int, value >= 0 else {
            return .default
        }
        return value == 0 ? .noLimit : HistorySizeLimit(byteLimit: value)
    }

    /// Both saved limits as one policy. Load the saved history with it, so loading deletes exactly what
    /// `applyStoredLimit()` would.
    nonisolated static func storedRetention(in defaults: UserDefaults) -> RetentionPolicy {
        RetentionPolicy(entryLimit: storedLimit(in: defaults), byteLimit: storedSizeLimit(in: defaults).byteLimit)
    }

    /// Applies the saved limits to the history at once, deleting the oldest entries that no longer fit.
    func applyStoredLimit() {
        history.setRetention(Self.storedRetention(in: defaults))
    }

    /// Describes what setting `newLimit` would do, without changing anything.
    func proposeLimit(_ newLimit: Int) -> LimitChange<Int> {
        let limit = RetentionPolicy.clamped(newLimit)
        return forecast(limit, under: history.retention.withEntryLimit(limit))
    }

    /// Saves `newLimit` and applies it, deleting the oldest entries that no longer fit.
    func applyLimit(_ newLimit: Int) {
        let limit = RetentionPolicy.clamped(newLimit)
        defaults.set(limit, forKey: SettingsKey.historyLimit)
        history.setLimit(limit)
    }

    /// Describes what setting `newLimit` would do, without changing anything.
    func proposeSizeLimit(_ newLimit: HistorySizeLimit) -> LimitChange<HistorySizeLimit> {
        forecast(newLimit, under: history.retention.withByteLimit(newLimit.byteLimit))
    }

    /// Saves `newLimit` and applies it, deleting the oldest entries that no longer fit. No limit is saved too.
    func applySizeLimit(_ newLimit: HistorySizeLimit) {
        defaults.set(newLimit.rawValue, forKey: SettingsKey.historyByteLimit)
        history.setRetention(history.retention.withByteLimit(newLimit.byteLimit))
    }

    /// What applying `policy` to the history would remove, reported as a change to `limit`.
    func forecast<Limit>(_ limit: Limit, under policy: RetentionPolicy) -> LimitChange<Limit> {
        let entries = history.entries
        let kept = policy.kept(entries)
        let totalBytes = entries.reduce(0) { $0 + $1.byteSize }
        let keptBytes = kept.reduce(0) { $0 + $1.byteSize }
        return LimitChange(limit: limit, removedCount: entries.count - kept.count, freedBytes: totalBytes - keptBytes)
    }
}
