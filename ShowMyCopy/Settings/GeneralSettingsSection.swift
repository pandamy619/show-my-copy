import AppKit
import SwiftUI

/// Settings → General, the page Settings open on: opening at login and pasting, the shortcut, and how to reach and
/// quit an app without a Dock or menu bar icon. The first launch's Settings show the one-time suggestion to open at
/// login at the top, before anything else.
struct GeneralSettingsPage<ShortcutRecorder: View>: View {
    let launchAtLogin: LaunchAtLoginSettings
    let paste: PasteSettings
    let shortcutRecorder: ShortcutRecorder

    var body: some View {
        Form {
            GeneralSettingsSection(launchAtLogin: launchAtLogin, paste: paste)
            Section("Shortcut") {
                LabeledContent("Show history") {
                    shortcutRecorder
                }
                Text(Self.shortcutNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            appSection
        }
        .formStyle(.grouped)
    }

    private static var shortcutNote: LocalizedStringKey {
        "Opens the clipboard history window. Avoid ⇧⌘V: it would replace Paste and Match Style in other apps."
    }

    /// The app has no Dock or menu bar icon, so this is the only place that says how to reach it and how to quit.
    /// Settings open on this page on the first launch, so a new user reads this there.
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
}

/// Settings → General: whether the app opens at login, and whether Return pastes the chosen entry. It is at the top
/// of the page, so the first launch's Settings show the one-time suggestion under the login toggle before anything
/// else.
///
/// What the toggles show comes from `LaunchAtLoginSettings` and `PasteSettings`, which ask macOS each time Settings
/// open or come to the front (`SettingsWindowController`).
struct GeneralSettingsSection: View {
    let launchAtLogin: LaunchAtLoginSettings
    let paste: PasteSettings

    var body: some View {
        Section("General") {
            Toggle(
                isOn: Binding(
                    get: { launchAtLogin.isOn },
                    set: { isOn in
                        Task {
                            await launchAtLogin.setOn(isOn)
                        }
                    }
                )
            ) {
                Text("Open at login")
                if launchAtLogin.showsSuggestion {
                    Text("Turn this on to keep recording your history from the moment you log in.")
                }
            }
            .disabled(!launchAtLogin.canChange)
            if let problem = launchAtLogin.problem {
                // A failed change never stops the app, so this is a note, not an alert. Details are in the log.
                Label {
                    Text(Self.message(for: problem))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
                openLoginItemsButton
            } else if launchAtLogin.needsApproval {
                footnotes {
                    Text("Allow Show My Copy in Login Items in System Settings to open it at login.")
                }
                openLoginItemsButton
            }
            pasteRows
        }
    }

    /// The paste toggle and what macOS allows. Turning it on asks macOS for permission to post key events
    /// (`PasteSettings.setOn(_:)`); the rows below say honestly whether the app has it now, and without it offer to
    /// open the Accessibility list in System Settings.
    @ViewBuilder private var pasteRows: some View {
        Toggle(
            isOn: Binding(
                get: { paste.isOn },
                set: { paste.setOn($0) }
            )
        ) {
            Text("Paste after choosing an entry")
            if !paste.isOn {
                Text("Return copies the entry. ⌥Return also pastes it into the app you were using.")
            } else if !paste.needsAccess {
                Text("Return pastes the entry into the app you were using. ⌥Return only copies it.")
            }
        }
        if !paste.isOn {
            if paste.access == .granted {
                // Turning the setting off cannot take the permission back; only the user can, in System Settings.
                footnotes {
                    Text("Show My Copy is still allowed to paste.")
                    Text("To take that back, turn it off in Privacy & Security → Accessibility in System Settings.")
                }
            }
        } else if paste.needsAccess {
            Label {
                Text("Show My Copy is not allowed to paste, so Return only copies.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            }
            footnotes {
                Text("Allow it in Privacy & Security → Accessibility in System Settings.")
                Text("To paste, Show My Copy sends ⌘V to the app you were using after you choose an entry.")
                Text("It never reads what you type.")
            }
            // macOS shows its own alert only the first time the app asks (turning the setting on); after that the user
            // can allow the app only in this list.
            Button("Open Privacy & Security…") {
                paste.openAccessibilitySettings()
            }
        } else {
            footnotes {
                Text("Show My Copy sends ⌘V only after you choose an entry and never reads what you type.")
            }
        }
    }

    private func footnotes<Lines: View>(@ViewBuilder _ lines: () -> Lines) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            lines()
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var openLoginItemsButton: some View {
        Button("Open Login Items…") {
            launchAtLogin.openLoginItems()
        }
    }

    private static func message(for problem: LaunchAtLoginSettings.Problem) -> LocalizedStringKey {
        switch problem {
        case .couldNotTurnOn:
            "Show My Copy could not be added to Login Items."
        case .couldNotTurnOff:
            "Show My Copy could not be removed from Login Items."
        }
    }
}
