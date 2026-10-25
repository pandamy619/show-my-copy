import Foundation
import Observation

/// What a limit control in Settings shows and does, for any `RetentionLimit`: a value the user picks that removes
/// nothing is applied at once; one that would remove entries waits in `pending` until the user confirms it.
///
/// The view binds its control to `value`, shows a confirmation while `pending` is set, and calls `historyChanged()`
/// when the history changes, `confirm()` / `cancel()` from the confirmation and `reset()` when it disappears.
@MainActor
@Observable
final class LimitDraft<Value: Equatable & Sendable> {
    @ObservationIgnored private let settings: HistorySettings
    @ObservationIgnored private let limit: RetentionLimit<Value>
    private var shown: Value
    /// The value picked that would remove entries, with what it removes. Applied only after `confirm()`.
    private(set) var pending: LimitChange<Value>?

    init(settings: HistorySettings, limit: RetentionLimit<Value>) {
        self.settings = settings
        self.limit = limit
        self.shown = settings.value(of: limit)
    }

    /// What the control shows. Setting it proposes the value: a value outside the allowed ones shows as the allowed
    /// one it becomes.
    var value: Value {
        get { shown }
        set { propose(newValue) }
    }

    /// The history changed while a confirmation is shown: what the pending value removes is checked again, and it
    /// is applied when it no longer removes anything.
    func historyChanged() {
        if let pending {
            propose(pending.limit)
        }
    }

    func confirm() {
        if let pending {
            settings.apply(pending.limit, for: limit)
        }
        reset()
    }

    func cancel() {
        reset()
    }

    /// Shows the value in effect and drops a pending one, for a fresh form.
    func reset() {
        pending = nil
        shown = settings.value(of: limit)
    }

    private func propose(_ newValue: Value) {
        let change = settings.propose(newValue, for: limit)
        shown = change.limit
        if change.needsConfirmation {
            pending = change
        } else {
            pending = nil
            if change.limit != settings.value(of: limit) {
                settings.apply(change.limit, for: limit)
            }
        }
    }
}
