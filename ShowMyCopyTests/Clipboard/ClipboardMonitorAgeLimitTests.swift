import Foundation
import Testing

@testable import ShowMyCopy

/// With an age limit, entries leave the history on time while the app idles: every poll looks for them, also when
/// nothing was copied.
@MainActor
struct ClipboardMonitorAgeLimitTests {
    private let pasteboard = FakePasteboard()
    private let environment = MonitorEnvironment()

    @Test func entriesPastTheAgeLimitAreRemovedOnAPollWithoutACopy() {
        let history = InMemoryHistoryStore(
            retention: RetentionPolicy(maxAge: .seconds(3600)), now: { [environment] in environment.now })
        let monitor = environment.makeMonitor(pasteboard: pasteboard, history: history)
        let start = environment.now
        pasteboard.copy("copied")
        monitor.poll()

        environment.now = start + 3599
        monitor.poll()
        #expect(history.entries.map(\.text) == ["copied"])

        environment.now = start + 3600
        monitor.poll()
        #expect(history.entries.isEmpty)
        #expect(history.currentEntryID == nil)
    }
}
