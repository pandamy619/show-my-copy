/// A page of the settings window, listed in the sidebar in this order with a coloured icon. Each page is one grouped
/// form. The titles and the colours are drawn in `SettingsSectionIcon.swift`, with SwiftUI.
enum SettingsSection: CaseIterable, Identifiable, Hashable, Sendable {
    /// Open at login, the shortcut and pasting. Holds the first launch's suggestion to open at login.
    case general
    /// The entry and age limits.
    case history
    /// What the history takes, the size limit and Clear History.
    case storage
    case passwords
    case excludedApps
    case about

    /// The colour of a page's icon. Plain names, so the order and the choice are tested without SwiftUI.
    enum Tint: Equatable, Sendable {
        case gray
        case blue
        case indigo
        case orange
        case red
    }

    /// The page Settings show when they open: the first launch's suggestion to open at login is there.
    static let initial: SettingsSection = .general

    var id: Self {
        self
    }

    /// The SF Symbol drawn in white on the page's tint.
    var symbolName: String {
        switch self {
        case .general:
            "gearshape"
        case .history:
            "clock.arrow.circlepath"
        case .storage:
            "internaldrive"
        case .passwords:
            "key.fill"
        case .excludedApps:
            "hand.raised.fill"
        case .about:
            "info"
        }
    }

    var tint: Tint {
        switch self {
        case .general, .about:
            .gray
        case .history:
            .blue
        case .storage:
            .indigo
        case .passwords:
            .orange
        case .excludedApps:
            .red
        }
    }

    /// The page the history window's note opens when choosing an entry only copied it: Paste after choosing an entry
    /// and whether macOS allows it are in General.
    static func showing(_ hint: PasteFallback) -> SettingsSection {
        switch hint {
        case .noAccess, .couldNotPost:
            .general
        }
    }
}
