import AppKit
import SwiftUI

/// The settings form. `shortcutRecorder` is the control that records the global shortcut.
struct SettingsView<ShortcutRecorder: View>: View {
    let history: any HistoryStore
    let settings: HistorySettings
    @Bindable var passwords: PasswordSettings
    let usage: StorageUsage
    let shortcutRecorder: ShortcutRecorder

    @State private var draftLimit: Int
    /// A lower limit the user picked that would delete entries. Applied only after they confirm.
    @State private var pendingLimit: Int?

    init(
        history: any HistoryStore,
        settings: HistorySettings,
        passwords: PasswordSettings,
        usage: StorageUsage,
        @ViewBuilder shortcutRecorder: () -> ShortcutRecorder
    ) {
        self.history = history
        self.settings = settings
        _passwords = Bindable(passwords)
        self.usage = usage
        self.shortcutRecorder = shortcutRecorder()
        _draftLimit = State(initialValue: settings.limit)
    }

    var body: some View {
        Form {
            shortcutSection
            limitSection
            StorageSection(settings: settings, usage: usage)
            ClearHistorySection(usage: usage)
            passwordsSection
            appSection
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: draftLimit) { _, newValue in
            draftLimitChanged(to: newValue)
        }
        .onChange(of: history.revision) {
            // The history can change while a confirmation is shown. Re-check what the change would do.
            draftLimitChanged(to: draftLimit)
        }
        .task {
            // Memory changes all the time, so it is read again while the settings are open. The window stays
            // loaded after it is closed, so later reads happen only while the app is in front.
            usage.refreshAppMemory()
            while true {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                if NSApplication.shared.isActive {
                    usage.refreshAppMemory()
                }
            }
        }
        .onDisappear(perform: resetDrafts)
    }

    private var shortcutSection: some View {
        Section("Shortcut") {
            LabeledContent("Show history") {
                shortcutRecorder
            }
            Text("Opens the clipboard history window. Avoid ⇧⌘V: it would replace Paste and Match Style in other apps.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var limitSection: some View {
        Section("History") {
            LabeledContent("Items to keep") {
                HStack(spacing: 6) {
                    TextField("Number of items", value: $draftLimit, format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                    Stepper("Number of items", value: $draftLimit, in: RetentionPolicy.entryLimitRange, step: 10)
                        .labelsHidden()
                }
            }
            LabeledContent("In history") {
                Text("\(history.entries.count) items now")
                    .monospacedDigit()
            }
            if let pendingLimit {
                let change = settings.proposeLimit(pendingLimit)
                InlineConfirmation(
                    message: .removingOldestItems(change.removedCount),
                    detail: .freeing(bytes: change.freedBytes),
                    confirmTitle: "Remove",
                    onConfirm: confirmPendingLimit,
                    onCancel: cancelPendingLimit
                )
            }
        }
    }

    private var passwordsSection: some View {
        Section("Passwords") {
            Toggle("Save passwords", isOn: $passwords.savesPasswords)
            Picker("Remove after", selection: $passwords.lifetime) {
                ForEach(PasswordLifetime.allCases) { lifetime in
                    Text(Self.title(of: lifetime)).tag(lifetime)
                }
            }
            .disabled(!passwords.savesPasswords)
            VStack(alignment: .leading, spacing: 4) {
                Text("When off, passwords and anything you copy from a password manager are not kept.")
                Text("When on, they are kept hidden in the history and removed after the time you choose.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func title(of lifetime: PasswordLifetime) -> LocalizedStringKey {
        switch lifetime {
        case .oneMinute:
            "1 minute"
        case .tenMinutes:
            "10 minutes"
        case .oneHour:
            "1 hour"
        }
    }

    /// The app has no Dock or menu bar icon, so this is the only place that says how to reach it and how to quit.
    /// Settings open on the first launch, so a new user reads this first.
    private var appSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Show My Copy has no Dock or menu bar icon.")
                Text("Press the shortcut above to show your history.")
                Text("To return to Settings, open Show My Copy again.")
            }
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Button("Quit Show My Copy") {
                NSApplication.shared.terminate(nil)
            }
        }
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
        draftLimit = settings.limit
        usage.forgetRecentClear()
    }
}
