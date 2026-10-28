/// What the app does when the user asks for the history from outside it, such as with the Control Center button.
/// `AppContainer` conforms.
@MainActor
protocol HistoryShowing: AnyObject {
    func showHistory()
}

/// Passes requests for the history from App Intents to the app. The app makes one at launch and registers it with
/// `AppDependencyManager`; `OpenHistoryIntent` gets it with `@Dependency`, so no global is needed.
///
/// The Control Center button can launch the app, and the history is loaded in the background before the container
/// exists: a request that arrives meanwhile opens the window once the container is connected.
///
/// This file is also built into the Control Center extension (a membership exception in the project), because the
/// intent declared there names this type. The extension never makes one: the intent runs only in the app.
@MainActor
final class HistoryRequests {
    /// Held weakly: App Intents keeps the registered requests for as long as the app runs.
    private weak var app: (any HistoryShowing)?
    private var showsWhenConnected = false

    /// Connects the app once it is ready, and shows the history if it was asked for meanwhile.
    func connect(_ app: any HistoryShowing) {
        self.app = app
        if showsWhenConnected {
            showsWhenConnected = false
            app.showHistory()
        }
    }

    func showHistory() {
        guard let app else {
            showsWhenConnected = true
            return
        }
        app.showHistory()
    }
}
