import SwiftUI

/// The settings: a sidebar of pages (`SettingsSection`) and the chosen page, each one grouped form.
/// `shortcutRecorder` is the control that records the global shortcut.
///
/// Each page keeps its own unconfirmed edits: going to another page drops them, as closing the window does, and
/// changes nothing.
struct SettingsView<ShortcutRecorder: View>: View {
    let settings: AppSettings
    @Bindable var navigation: SettingsNavigation
    /// Copies text selected in Settings without recording it.
    let copyText: @MainActor (String) -> Void
    let shortcutRecorder: ShortcutRecorder

    init(
        settings: AppSettings,
        navigation: SettingsNavigation,
        copyText: @escaping @MainActor (String) -> Void,
        @ViewBuilder shortcutRecorder: () -> ShortcutRecorder
    ) {
        self.settings = settings
        _navigation = Bindable(navigation)
        self.copyText = copyText
        self.shortcutRecorder = shortcutRecorder()
    }

    var body: some View {
        // Always both columns: the sidebar toggle is removed, so a collapsed sidebar could not come back.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(SettingsSection.allCases, selection: $navigation.selection) { section in
                Label {
                    Text(section.title)
                } icon: {
                    SettingsSectionIcon(section: section)
                }
                .tag(section)
            }
            // Wider than Show My IP's 190 so the Russian section names fit.
            .navigationSplitViewColumnWidth(220)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail(for: navigation.shown)
                .navigationTitle(Text(navigation.shown.title))
        }
        .frame(width: 720, height: 480)
    }

    @ViewBuilder private func detail(for section: SettingsSection) -> some View {
        switch section {
        case .general:
            GeneralSettingsPage(
                launchAtLogin: settings.launchAtLogin, paste: settings.paste, shortcutRecorder: shortcutRecorder)
        case .history:
            HistorySettingsPage(history: settings.store, settings: settings.history)
        case .storage:
            StorageSettingsPage(settings: settings.history, usage: settings.storage)
        case .passwords:
            PasswordsSettingsPage(passwords: settings.passwords)
        case .excludedApps:
            Form {
                ExcludedAppsSection(apps: settings.excludedApps)
            }
            .formStyle(.grouped)
        case .about:
            AboutSettingsPage(copyText: copyText)
        }
    }
}
