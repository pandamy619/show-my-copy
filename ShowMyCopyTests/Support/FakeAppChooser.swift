@testable import ShowMyCopy

/// Stands in for the open panel of Settings → Excluded apps: returns the app a test gives, or nil for a cancel.
/// With `gate` armed, a choice waits there, as while the panel is open.
@MainActor
final class FakeAppChooser: AppChoosing {
    var chosen: ChosenApp?
    let gate = AsyncGate()
    private(set) var count = 0

    init(_ chosen: ChosenApp? = nil) {
        self.chosen = chosen
    }

    func chooseApp() async -> ChosenApp? {
        count += 1
        await gate.pass()
        return chosen
    }
}
