import Foundation
import Testing

/// An empty UserDefaults suite for one test, so tests never read or change the app's settings or each other's.
enum TestDefaults {
    /// Runs `body` with a fresh suite that is removed afterwards. `ContainerFactory.withDefaults` is the same for
    /// async tests on the main actor.
    static func with(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "ShowMyCopyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
