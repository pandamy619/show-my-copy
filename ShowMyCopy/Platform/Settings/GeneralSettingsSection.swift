import SwiftUI

/// Settings → General: whether the app opens at login. It is at the top, so the first launch's Settings show the
/// one-time suggestion next to the toggle before anything else.
///
/// What the toggle shows comes from `LaunchAtLoginSettings`, which asks macOS each time Settings open or come to the
/// front (`SettingsWindowController`).
struct GeneralSettingsSection: View {
    let launchAtLogin: LaunchAtLoginSettings

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
        }
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
