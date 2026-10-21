/// Opens the settings window. `SettingsWindowController` is built with SwiftUI, so `AppContainer` gets it through
/// this protocol from a factory and does not depend on SwiftUI itself.
@MainActor
protocol SettingsWindowShowing: AnyObject {
    /// Opens the settings window, or brings it to the front if it is already open.
    func show()
}
