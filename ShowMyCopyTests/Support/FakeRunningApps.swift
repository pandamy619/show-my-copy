@testable import ShowMyCopy

/// The apps a test says are open, in the order it gives them.
@MainActor
final class FakeRunningApps: RunningAppsListing {
    var apps: [SourceApp]

    init(_ apps: [SourceApp] = []) {
        self.apps = apps
    }

    func runningApps() -> [SourceApp] {
        apps
    }
}
