import SwiftUI

/// Settings → General: whether the app opens at login, and whether Return pastes the chosen entry. It is at the top,
/// so the first launch's Settings show the one-time suggestion next to the login toggle before anything else.
///
/// What the toggles show comes from `LaunchAtLoginSettings` and `PasteSettings`, which ask macOS each time Settings
/// open or come to the front (`SettingsWindowController`).
struct GeneralSettingsSection: View {
    let launchAtLogin: LaunchAtLoginSettings
    let paste: PasteSettings

    var body: some View {
        Section("General") {
            Toggle(
                "Open at login",
                isOn: Binding(
                    get: { launchAtLogin.isOn },
                    set: { isOn in
                        Task {
                            await launchAtLogin.setOn(isOn)
                        }
                    }
                )
            )
            .disabled(!launchAtLogin.canChange)
            if launchAtLogin.showsSuggestion {
                caption("Turn this on to keep recording your history from the moment you log in.")
            }
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
                caption("Allow Show My Copy in Login Items in System Settings to open it at login.")
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
            "Paste after choosing an entry",
            isOn: Binding(
                get: { paste.isOn },
                set: { paste.setOn($0) }
            )
        )
        if !paste.isOn {
            captions {
                Text("Return copies the entry. ⌥Return also pastes it into the app you were using.")
                if paste.access == .granted {
                    // Turning the setting off cannot take the permission back; only the user can, in System Settings.
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
            captions {
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
            captions {
                Text("Return pastes the entry into the app you were using. ⌥Return only copies it.")
                Text("Show My Copy sends ⌘V only after you choose an entry and never reads what you type.")
            }
        }
    }

    private func captions<Lines: View>(@ViewBuilder _ lines: () -> Lines) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            lines()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var openLoginItemsButton: some View {
        Button("Open Login Items…") {
            launchAtLogin.openLoginItems()
        }
    }

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
