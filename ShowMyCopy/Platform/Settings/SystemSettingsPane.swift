import AppKit

/// Opens System Settings at Privacy & Security → Accessibility, where the user allows Show My Copy to paste
/// (Settings → General → Paste after choosing an entry).
///
/// This is the one file the app allows to hand anything to another app (SECURITY.md): `.swiftlint.yml` excludes only
/// this path from `no_external_handoff`, and `scripts/check_security.py` checks it instead. Each address is a fixed
/// literal of the System Settings scheme, made into a URL and opened in one expression, and nothing here takes a
/// parameter, so nothing the user copied can reach System Settings or any other app. The checker fails on any other
/// address, any address built from something else, any other way of opening something and any parameter.
///
/// macOS 13 renamed the panes when System Preferences became System Settings. The Privacy & Security extension's
/// address is the one apps use on macOS 26; macOS 15 still answers the address of the old Security & Privacy pane,
/// which apps have used for years. Each version tries its own first and the other when that cannot be opened.
@MainActor
final class SystemSettingsPane: AccessibilitySettingsOpening {
    func openAccessibilityList() {
        let opened: Bool
        if #available(macOS 26, *) {
            opened = Self.showPrivacySecurityExtension() || Self.showSecurityPreferencePane()
        } else {
            opened = Self.showSecurityPreferencePane() || Self.showPrivacySecurityExtension()
        }
        if !opened {
            AppLogger.app.error("System Settings could not be opened at Privacy & Security")
        }
    }

    /// System Settings' own address for the list, since macOS 13.
    private static func showPrivacySecurityExtension() -> Bool {
        URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")
            .map { NSWorkspace.shared.open($0) } ?? false
    }

    /// The address of the same list in System Preferences before macOS 13, which System Settings still answer.
    private static func showSecurityPreferencePane() -> Bool {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            .map { NSWorkspace.shared.open($0) } ?? false
    }
}
