import Foundation
import Observation

/// The result of asking for a new history limit, before it is applied.
struct LimitChange: Equatable, Sendable {
    /// The requested limit, clamped to `RetentionPolicy.entryLimitRange`.
    let limit: Int
    /// How many of the oldest entries the new limit would delete.
    let removedCount: Int

    /// True when applying the limit deletes entries, so the user should confirm first.
    var needsConfirmation: Bool { removedCount > 0 }
}

/// Stores the history limit in UserDefaults and applies it to the clipboard history.
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

    /// The saved limit, or the default when nothing valid is saved. Always within `RetentionPolicy.entryLimitRange`.
    nonisolated static func storedLimit(in defaults: UserDefaults) -> Int {
        guard let value = defaults.object(forKey: SettingsKey.historyLimit) as? Int else {
            return RetentionPolicy.defaultEntryLimit
        }
        return RetentionPolicy.clamped(value)
    }

    /// Applies the saved limit to the history, deleting the oldest entries that no longer fit.
    func applyStoredLimit() {
        history.setLimit(Self.storedLimit(in: defaults))
    }

    /// Describes what setting `newLimit` would do, without changing anything.
    func proposeLimit(_ newLimit: Int) -> LimitChange {
        let limit = RetentionPolicy.clamped(newLimit)
        return LimitChange(limit: limit, removedCount: history.entriesRemoved(byLimit: limit))
    }

    /// Saves `newLimit` and applies it, deleting the oldest entries that no longer fit.
    func applyLimit(_ newLimit: Int) {
        let limit = RetentionPolicy.clamped(newLimit)
        defaults.set(limit, forKey: SettingsKey.historyLimit)
        history.setLimit(limit)
    }
}
