import SwiftUI

/// Settings → Passwords: whether passwords are kept, hidden, and for how long.
struct PasswordsSettingsPage: View {
    @Bindable var passwords: PasswordSettings

    var body: some View {
        Form {
            Section("Passwords") {
                Toggle(isOn: $passwords.savesPasswords) {
                    Text("Save passwords")
                    Text("Keeps passwords hidden in the history and removes them after the time you choose.")
                }
                Picker("Remove after", selection: $passwords.lifetime) {
                    ForEach(PasswordLifetime.allCases) { lifetime in
                        Text(Self.title(of: lifetime)).tag(lifetime)
                    }
                }
                .disabled(!passwords.savesPasswords)
                Text("When off, passwords and anything you copy from a password manager are not kept.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
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
}
