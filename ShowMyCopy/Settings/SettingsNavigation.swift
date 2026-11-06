import Observation

/// Which page the settings window shows. The sidebar binds to `selection`; the window controller keeps this for as
/// long as the window lives, moves it to a page a caller asks for and back to the first page when the window closes,
/// so Settings open on General each time. The page is not saved.
@MainActor
@Observable
final class SettingsNavigation {
    /// The page selected in the sidebar. Nil when the user deselects it, such as with a ⌘-click.
    var selection: SettingsSection? = SettingsSection.initial

    /// The page the detail shows: the first page while nothing is selected.
    var shown: SettingsSection {
        selection ?? SettingsSection.initial
    }

    /// Shows `section`, or, with nil, keeps the page shown now: the window is only brought to the front.
    func show(_ section: SettingsSection?) {
        if let section {
            selection = section
        }
    }

    /// The window closed: it opens on the first page next time.
    func windowClosed() {
        selection = SettingsSection.initial
    }
}
