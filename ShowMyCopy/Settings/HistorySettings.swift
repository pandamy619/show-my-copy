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
/// 1 GB is the default, for everyone who has not chosen: images can make the history several gigabytes, and the
/// entry limit alone does not stop that. A saved choice, including No limit, stays.
enum HistorySizeLimit: Int, CaseIterable, Identifiable, Sendable {
    case noLimit = 0
    case megabytes100 = 100_000_000
    case megabytes500 = 500_000_000
    case gigabyte1 = 1_000_000_000

    static let `default` = HistorySizeLimit.gigabyte1

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

/// Stores the history limits in UserDefaults and applies them to the clipboard history. Every limit works the same
/// way (`RetentionLimit`): read it with `value(of:)`, see what a new value would remove with `propose`, and save and
/// apply it with `apply`.
@MainActor
@Observable
final class HistorySettings {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let history: any HistoryStore
    /// The time a forecast measures the age limit against: the history's clock.
    @ObservationIgnored private let now: @MainActor () -> Date

    /// Leaves `history` as it is. Call `applyStoredLimits()` when the app starts, before the first entry is
    /// recorded. Creating the settings does not change the history, so the app decides when that happens.
    init(history: any HistoryStore, defaults: UserDefaults, now: @escaping @MainActor () -> Date) {
        self.history = history
        self.defaults = defaults
        self.now = now
    }

    /// The value of `limit` in effect. The history is the single source of truth.
    func value<Value>(of limit: RetentionLimit<Value>) -> Value {
        limit.value(history.retention)
    }

    /// The entry limit in effect.
    var limit: Int { value(of: .entries) }

    /// The size limit in effect, as one of the options.
    var sizeLimit: HistorySizeLimit { value(of: .size) }

    /// Every saved limit as one policy. Load the saved history with it, so loading deletes exactly what
    /// `applyStoredLimits()` would.
    nonisolated static func storedRetention(in defaults: UserDefaults) -> RetentionPolicy {
        RetentionLimits.stored(in: defaults)
    }

    /// Applies the saved limits to the history at once, deleting the oldest entries that no longer fit.
    func applyStoredLimits() {
        history.setRetention(Self.storedRetention(in: defaults))
    }

    /// Describes what setting `limit` to `newValue` would do, without changing anything. The change holds the value
    /// as it would be applied, such as an entry limit moved into its range.
    func propose<Value>(_ newValue: Value, for limit: RetentionLimit<Value>) -> LimitChange<Value> {
        let value = limit.normalized(newValue)
        return forecast(value, under: limit.apply(value, history.retention))
    }

    /// Saves `newValue` for `limit` and applies it, deleting the oldest entries that no longer fit. Every choice is
    /// saved, also No limit, so a later default does not override it.
    func apply<Value>(_ newValue: Value, for limit: RetentionLimit<Value>) {
        let value = limit.normalized(newValue)
        limit.save(value, in: defaults)
        history.setRetention(limit.apply(value, history.retention))
    }

    /// What applying `policy` to the history now would remove, reported as a change to `limit`.
    func forecast<Limit>(_ limit: Limit, under policy: RetentionPolicy) -> LimitChange<Limit> {
        let entries = history.entries
        let kept = policy.kept(entries, at: now())
        let totalBytes = entries.reduce(0) { $0 + $1.byteSize }
        let keptBytes = kept.reduce(0) { $0 + $1.byteSize }
        return LimitChange(limit: limit, removedCount: entries.count - kept.count, freedBytes: totalBytes - keptBytes)
    }
}
