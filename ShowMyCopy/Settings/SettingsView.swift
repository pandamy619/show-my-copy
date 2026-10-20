import SwiftUI

/// The settings form. `shortcutRecorder` is the control that records the global shortcut.
struct SettingsView<ShortcutRecorder: View>: View {
    let history: ClipboardHistory
    let settings: HistorySettings
    let shortcutRecorder: ShortcutRecorder

    @State private var draftLimit: Int
    /// A lower limit the user picked that would delete entries. Applied only after they confirm.
    @State private var pendingLimit: Int?
    @State private var isConfirmingClear = false

    init(
        history: ClipboardHistory,
        settings: HistorySettings,
        @ViewBuilder shortcutRecorder: () -> ShortcutRecorder
    ) {
        self.history = history
        self.settings = settings
        self.shortcutRecorder = shortcutRecorder()
        _draftLimit = State(initialValue: settings.limit)
    }

    var body: some View {
        Form {
            shortcutSection
            limitSection
            clearSection
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: draftLimit) { _, newValue in
            draftLimitChanged(to: newValue)
        }
        .onChange(of: history.entries.count) { _, count in
            // The history can change while a confirmation is shown. Re-check what the change would do.
            draftLimitChanged(to: draftLimit)
            if count == 0 {
                isConfirmingClear = false
            }
        }
        .onDisappear(perform: resetDrafts)
    }

    private var shortcutSection: some View {
        Section("Shortcut") {
            LabeledContent("Show history") {
                shortcutRecorder
            }
            Text("Opens the clipboard history window")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var limitSection: some View {
        Section("History") {
            LabeledContent("Keep the last") {
                HStack(spacing: 6) {
                    TextField("Number of items", value: $draftLimit, format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                    Stepper("Number of items", value: $draftLimit, in: ClipboardHistory.limitRange, step: 10)
                        .labelsHidden()
                    Text("items")
                }
            }
            LabeledContent("In history") {
                Text("^[\(history.entries.count) item](inflect: true) now")
                    .monospacedDigit()
            }
            if let pendingLimit {
                InlineConfirmation(
                    message: removalMessage(count: history.entriesRemoved(byLimit: pendingLimit)),
                    confirmTitle: "Remove",
                    onConfirm: confirmPendingLimit,
                    onCancel: cancelPendingLimit
                )
            }
        }
    }

    private var clearSection: some View {
        Section {
            if isConfirmingClear {
                InlineConfirmation(
                    message: Text("This removes all items from your history."),
                    confirmTitle: "Remove All",
                    onConfirm: {
                        history.clear()
                        isConfirmingClear = false
                    },
                    onCancel: { isConfirmingClear = false }
                )
            } else {
                Button("Clear History…") {
                    isConfirmingClear = true
                }
                .disabled(history.entries.isEmpty)
            }
        }
    }

    private func removalMessage(count: Int) -> Text {
        count == 1
            ? Text("This removes your oldest item.")
            : Text("This removes \(count) of your oldest items.")
    }

    private func draftLimitChanged(to value: Int) {
        let change = settings.proposeLimit(value)
        guard change.limit == value else {
            // Out of range: show the clamped value. This calls back here with it.
            draftLimit = change.limit
            return
        }
        if change.needsConfirmation {
            pendingLimit = change.limit
        } else {
            pendingLimit = nil
            if change.limit != settings.limit {
                settings.applyLimit(change.limit)
            }
        }
    }

    private func confirmPendingLimit() {
        if let pendingLimit {
            settings.applyLimit(pendingLimit)
        }
        pendingLimit = nil
        draftLimit = settings.limit
    }

    private func cancelPendingLimit() {
        pendingLimit = nil
        draftLimit = settings.limit
    }

    private func resetDrafts() {
        pendingLimit = nil
        isConfirmingClear = false
        draftLimit = settings.limit
    }
}

/// A question shown in place, with a destructive confirm button and a cancel button.
private struct InlineConfirmation: View {
    let message: Text
    let confirmTitle: LocalizedStringKey
    let onConfirm: @MainActor () -> Void
    let onCancel: @MainActor () -> Void

    var body: some View {
        HStack {
            message
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Cancel", action: onCancel)
            Button(confirmTitle, role: .destructive, action: onConfirm)
        }
        .accessibilityElement(children: .contain)
    }
}
