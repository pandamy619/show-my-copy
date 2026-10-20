import Foundation
import Observation

/// The result of asking for a new history limit, before it is applied.
struct LimitChange: Equatable, Sendable {
    /// The requested limit, clamped to `ClipboardHistory.limitRange`.
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
    @ObservationIgnored let history: ClipboardHistory

    /// Reads the saved limit and applies it to `history`.
    init(history: ClipboardHistory, defaults: UserDefaults = .standard) {
        self.history = history
        self.defaults = defaults
        history.setLimit(Self.storedLimit(in: defaults))
    }

    /// The limit in effect. The history is the single source of truth.
    var limit: Int { history.limit }

    /// The saved limit, or the default when nothing valid is saved. Always within `ClipboardHistory.limitRange`.
    nonisolated static func storedLimit(in defaults: UserDefaults) -> Int {
        guard let value = defaults.object(forKey: SettingsKey.historyLimit) as? Int else {
            return ClipboardHistory.defaultLimit
        }
        return clamped(value)
    }

    /// Describes what setting `newLimit` would do, without changing anything.
    func proposeLimit(_ newLimit: Int) -> LimitChange {
        let limit = Self.clamped(newLimit)
        return LimitChange(limit: limit, removedCount: history.entriesRemoved(byLimit: limit))
    }

    /// Saves `newLimit` and applies it, deleting the oldest entries that no longer fit.
    func applyLimit(_ newLimit: Int) {
        let limit = Self.clamped(newLimit)
        defaults.set(limit, forKey: SettingsKey.historyLimit)
        history.setLimit(limit)
    }

    private nonisolated static func clamped(_ value: Int) -> Int {
        let range = ClipboardHistory.limitRange
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
