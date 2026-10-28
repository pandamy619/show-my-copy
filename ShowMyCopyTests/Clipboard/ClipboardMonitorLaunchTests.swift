import Foundation
import Testing

@testable import ShowMyCopy

/// The history may already hold entries when the app starts, since it is saved. The pasteboard then usually still
/// holds the newest entry, which must not be rewritten on every launch.
@MainActor
struct ClipboardMonitorLaunchTests {
    private let pasteboard = FakePasteboard()
    private let history = InMemoryHistoryStore()
    private let yesterday = Date(timeIntervalSince1970: 1_790_000_000)
    private let now = Date(timeIntervalSince1970: 1_790_000_100)
    private let notes = SourceApp(bundleIdentifier: "com.apple.Notes", name: "Notes")
    private let safari = SourceApp(bundleIdentifier: "com.apple.Safari", name: "Safari")

    private func makeMonitor() -> ClipboardMonitor {
        MonitorFactory.make(
            pasteboard: pasteboard,
            history: history,
            frontmostApp: { [safari] in safari },
            now: { [now] in now },
            passwordPolicy: { PasswordPolicy(savesPasswords: true, lifetime: 600) }
        )
    }

    /// Fills the history as if it was loaded at launch: no entry is known to be on the pasteboard yet.
    private func prefill(_ texts: [String]) {
        for (offset, text) in texts.reversed().enumerated() {
            history.record(text: text, sourceApp: notes, at: yesterday - Double(texts.count - 1 - offset))
        }
        history.markCurrentSkipped()
    }

    @Test func firstPollLeavesTheNewestEntryAsItIs() throws {
        prefill(["copied yesterday", "older"])
        let before = try #require(history.entries.first)
        pasteboard.copy("copied yesterday")

        makeMonitor().poll()
        #expect(history.entries.first == before)
        #expect(history.entries.map(\.text) == ["copied yesterday", "older"])
        #expect(history.currentEntryID == before.id)
    }

    @Test func firstPollLeavesAConcealedNewestEntryAndItsExpiry() throws {
        history.record(
            text: "hunter2", sourceApp: notes, at: yesterday, concealed: true, expiresAt: yesterday + 600)
        history.markCurrentSkipped()
        let before = try #require(history.entries.first)
        pasteboard.copy("hunter2", markers: [PasteboardMarker.concealed])

        makeMonitor().poll()
        #expect(history.entries.first == before)
        #expect(history.currentEntryID == before.id)
    }

    @Test func firstPollConcealsAPlainNewestEntryThatThePasteboardMarksAsAPassword() throws {
        prefill(["hunter2"])
        let before = try #require(history.entries.first)
        pasteboard.copy("hunter2", markers: [PasteboardMarker.concealed])

        makeMonitor().poll()
        let entry = try #require(history.entries.first)
        #expect(entry.id == before.id)
        #expect(entry.isConcealed)
        #expect(entry.expiresAt == now + 600)
        #expect(entry.date == before.date)
        #expect(entry.sourceApp == notes)
    }

    @Test func firstPollRecordsOtherContentAsACopyFromAnUnknownApp() throws {
        prefill(["copied yesterday"])
        pasteboard.copy("copied while the app was not running")

        makeMonitor().poll()
        let entry = try #require(history.entries.first)
        #expect(entry.text == "copied while the app was not running")
        #expect(entry.date == now)
        #expect(entry.sourceApp == nil)
        #expect(history.currentEntryID == entry.id)
    }

    @Test func firstPollMovesAnOlderEntryThatThePasteboardHolds() throws {
        prefill(["newest", "older"])
        pasteboard.copy("older")

        makeMonitor().poll()
        let entry = try #require(history.entries.first)
        #expect(entry.text == "older")
        #expect(entry.date == now)
        #expect(entry.sourceApp == nil)
    }

    @Test func copyingTheNewestTextAgainAfterLaunchUpdatesIt() throws {
        prefill(["copied yesterday"])
        pasteboard.copy("copied yesterday")
        let monitor = makeMonitor()
        monitor.poll()

        pasteboard.copy("copied yesterday")
        monitor.poll()
        let entry = try #require(history.entries.first)
        #expect(history.entries.count == 1)
        #expect(entry.date == now)
        #expect(entry.sourceApp == safari)
    }
}
