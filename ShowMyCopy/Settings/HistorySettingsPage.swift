import SwiftUI

/// Settings → History: how many entries to keep and for how long, and that pinned entries are kept.
struct HistorySettingsPage: View {
    let history: any HistoryStore

    /// The entry limit being picked. A lower limit that would delete entries is applied only after the user
    /// confirms it.
    @State private var entryLimit: LimitDraft<Int>
    /// The age limit being picked. A shorter limit that would delete entries is applied only after the user
    /// confirms it.
    @State private var ageLimit: LimitDraft<HistoryAgeLimit>

    init(history: any HistoryStore, settings: HistorySettings) {
        self.history = history
        _entryLimit = State(initialValue: LimitDraft(settings: settings, limit: .entries))
        _ageLimit = State(initialValue: LimitDraft(settings: settings, limit: .age))
    }

    var body: some View {
        Form {
            Section("History") {
                entryLimitRows
            }
            Section {
                ageLimitRows
            }
        }
        .formStyle(.grouped)
        .onChange(of: history.revision) {
            // The history can change while a confirmation is shown. Re-check what the change would do.
            entryLimit.historyChanged()
            ageLimit.historyChanged()
        }
        // Also when the user goes to another page: an edit that was never confirmed changes nothing.
        .onDisappear {
            entryLimit.reset()
            ageLimit.reset()
        }
    }

    // Split from body: one builder with every row is too much for the type checker.
    @ViewBuilder private var entryLimitRows: some View {
        LabeledContent("Items to keep") {
            HStack(spacing: 6) {
                TextField("Number of items", value: $entryLimit.value, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                Stepper(
                    "Number of items", value: $entryLimit.value, in: RetentionPolicy.entryLimitRange, step: 10
                )
                .labelsHidden()
            }
        }
        LabeledContent("In history") {
            Text("\(history.entries.count) items now")
                .monospacedDigit()
        }
        if let change = entryLimit.pending {
            InlineConfirmation(
                message: .removingOldestItems(change.removedCount),
                detail: .freeing(change),
                confirmTitle: "Remove",
                onConfirm: { entryLimit.confirm() },
                onCancel: { entryLimit.cancel() }
            )
        } else {
            let maximum = RetentionPolicy.maximumPinned
            Text("Pinned entries don't count. Up to \(maximum) can be pinned; one more unpins the oldest.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var ageLimitRows: some View {
        Picker("Remove items after", selection: $ageLimit.value) {
            ForEach(HistoryAgeLimit.options, id: \.self) { limit in
                Self.title(of: limit).tag(limit)
            }
        }
        if let change = ageLimit.pending {
            // Entries past the age limit are always the oldest ones that are not pinned.
            InlineConfirmation(
                message: .removingOldestItems(change.removedCount),
                detail: .freeing(change),
                confirmTitle: "Remove",
                onConfirm: { ageLimit.confirm() },
                onCancel: { ageLimit.cancel() }
            )
        } else {
            Text("Entries older than this are removed automatically. Pinned entries are kept.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Hours and days are plural strings in the catalog, such as "1 hour" and "8 hours".
    private static func title(of limit: HistoryAgeLimit) -> Text {
        switch limit.span {
        case .hours(let count):
            Text("\(count) hours")
        case .days(let count):
            Text("\(count) days")
        case nil:
            Text("Off", comment: "The history age limit option that keeps entries until the user removes them.")
        }
    }
}
