import AppKit
import SwiftUI

extension SettingsSection {
    /// The page's name in the sidebar. Kept here, with SwiftUI, because only Apple's Foundation localizes strings.
    var title: LocalizedStringResource {
        switch self {
        case .general:
            "General"
        case .history:
            "History"
        case .storage:
            "Storage"
        case .passwords:
            "Passwords"
        case .excludedApps:
            "Excluded apps"
        case .about:
            "About"
        }
    }
}

extension SettingsSection.Tint {
    /// System colours, which adapt to light and dark mode.
    var color: Color {
        switch self {
        case .gray:
            .gray
        case .blue:
            .blue
        case .indigo:
            .indigo
        case .orange:
            .orange
        case .red:
            .red
        }
    }
}

/// A page's icon in the sidebar: its symbol in white on a rounded square of its colour, as in System Settings.
struct SettingsSectionIcon: View {
    let section: SettingsSection

    var body: some View {
        Image(systemName: section.symbolName)
            // The system font at 11 points, semibold. Made with AppKit: the checks against running processes
            // (`no_shell_execution`, `scripts/check_security.py`) cannot tell SwiftUI's system font from the C
            // function of that name.
            .font(Font(NSFont.systemFont(ofSize: 11, weight: .semibold) as CTFont))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(section.tint.color.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            // The title next to it names the page.
            .accessibilityHidden(true)
    }
}
