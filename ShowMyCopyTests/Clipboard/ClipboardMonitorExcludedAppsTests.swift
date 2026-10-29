import Foundation
import Testing

@testable import ShowMyCopy

/// Copies made while an excluded app is in front are left alone before anything is read from the pasteboard, in the
/// same place as the password manager check and with the same rule for a change whose source is unknown: that one is
/// recorded.
@MainActor
struct ClipboardMonitorExcludedAppsTests {
    private let pasteboard = FakePasteboard()
    private let history = InMemoryHistoryStore()
    private let environment = MonitorEnvironment()
    private let safari = SourceApp(bundleIdentifier: "com.apple.Safari", name: "Safari")
    private let textEdit = SourceApp(bundleIdentifier: "com.apple.TextEdit", name: "TextEdit")
    private let onePassword = SourceApp(bundleIdentifier: "com.1password.1password", name: "1Password")

    init() {
        environment.excludedApps = ["com.apple.textedit"]
    }

    /// A monitor that recorded "before" from Safari, so the next copy has a known source app.
    private func makeWatchingMonitor() -> ClipboardMonitor {
        environment.frontmostApp = safari
        let monitor = environment.makeMonitor(pasteboard: pasteboard, history: history)
        pasteboard.copy("before")
        monitor.poll()
        return monitor
    }

    /// Every read of the pasteboard's contents or types so far.
    private var reads: [Int] {
        [
            pasteboard.typesReadCount, pasteboard.stringCallCount, pasteboard.dataReadCount,
            pasteboard.fileURLReadCount,
        ]
    }

    @Test func copyInAnExcludedAppIsNotReadOrRecorded() {
        let monitor = makeWatchingMonitor()
        environment.frontmostApp = textEdit
        pasteboard.copy("private note")
        let readsBefore = reads

        monitor.poll()

        #expect(reads == readsBefore)
        #expect(history.entries.map(\.text) == ["before"])
    }

    @Test func excludedCopyIsNotCurrentAndNeitherIsTheEntryBefore() {
        let monitor = makeWatchingMonitor()
        #expect(history.currentEntryID == history.entries.first?.id)
        environment.frontmostApp = textEdit
        pasteboard.copy("private note")

        monitor.poll()

        #expect(history.currentEntryID == nil)
        #expect(monitor.handledChangeCount == pasteboard.changeCount)
    }

    @Test(arguments: ["com.apple.TextEdit", "COM.APPLE.TEXTEDIT"])
    func excludedImagesFilesAndRichTextAreNotReadEither(bundleIdentifier: String) {
        let monitor = makeWatchingMonitor()
        environment.frontmostApp = SourceApp(bundleIdentifier: bundleIdentifier, name: "TextEdit")
        let readsBefore = reads

        pasteboard.copyRichText("styled")
        monitor.poll()
        pasteboard.copyImage()
        monitor.poll()
        pasteboard.copyFiles([URL(filePath: "/Users/me/secret.pdf")])
        monitor.poll()

        #expect(reads == readsBefore)
        #expect(history.entries.map(\.text) == ["before"])
    }

    @Test func excludedPasswordManagerIsNotReadEvenWhilePasswordsAreSaved() {
        environment.excludedApps = ["com.1password.1password"]
        environment.savePasswords()
        let monitor = makeWatchingMonitor()
        environment.frontmostApp = onePassword
        pasteboard.copy("hunter2", markers: [PasteboardMarker.concealed])
        let readsBefore = reads

        monitor.poll()

        #expect(reads == readsBefore)
        #expect(history.entries.map(\.text) == ["before"])
    }

    @Test func theNextCopyInAnotherAppIsRecordedWithItsApp() {
        let monitor = makeWatchingMonitor()
        environment.frontmostApp = textEdit
        pasteboard.copy("private note")
        monitor.poll()
        // Nothing changed since: the excluded copy is not looked at again.
        monitor.poll()
        #expect(history.entries.map(\.text) == ["before"])

        environment.frontmostApp = safari
        pasteboard.copy("after")
        monitor.poll()

        #expect(history.entries.map(\.text) == ["after", "before"])
        #expect(history.entries.first?.sourceApp == safari)
        #expect(history.currentEntryID == history.entries.first?.id)
    }

    @Test func appIsRecordedAgainOnceItIsNoLongerExcluded() {
        let monitor = makeWatchingMonitor()
        environment.frontmostApp = textEdit
        pasteboard.copy("private note")
        monitor.poll()

        environment.excludedApps = []
        pasteboard.copy("shared note")
        monitor.poll()

        #expect(history.entries.map(\.text) == ["shared note", "before"])
        #expect(history.entries.first?.sourceApp == textEdit)
    }

    // MARK: Unknown source

    @Test func whatIsOnThePasteboardAtLaunchIsRecordedEvenWithAnExcludedAppInFront() {
        environment.frontmostApp = textEdit
        let monitor = environment.makeMonitor(pasteboard: pasteboard, history: history)
        pasteboard.copy("copied before launch")

        monitor.poll()

        #expect(history.entries.map(\.text) == ["copied before launch"])
        #expect(history.entries.first?.sourceApp == nil)
    }

    @Test func copyFoundRightAfterAPauseIsRecordedWithoutAnApp() {
        let monitor = makeWatchingMonitor()
        monitor.start()
        monitor.pause(for: .screenLocked)
        // Copied on another device through Universal Clipboard while the Mac was locked; TextEdit is in front after.
        pasteboard.copy("from my phone")
        environment.frontmostApp = textEdit

        monitor.resume(for: .screenLocked)
        monitor.poll()

        #expect(history.entries.map(\.text) == ["from my phone", "before"])
        #expect(history.entries.first?.sourceApp == nil)

        // The next copy has a known source again, so the exclusion applies.
        pasteboard.copy("private note")
        monitor.poll()
        #expect(history.entries.map(\.text) == ["from my phone", "before"])
        monitor.stop()
    }

    // MARK: Emptied clipboard

    @Test func excludedAppEmptyingTheClipboardRemovesNothing() {
        let monitor = makeWatchingMonitor()
        pasteboard.copy("hunter2")
        monitor.poll()
        environment.frontmostApp = textEdit
        let readsBefore = reads

        pasteboard.clear()
        monitor.poll()
        monitor.poll()

        #expect(reads == readsBefore)
        #expect(history.entries.map(\.text) == ["hunter2", "before"])
        #expect(history.entries.allSatisfy { !$0.isConcealed })
    }

    @Test func switchingToAnExcludedAppWhileAnEmptiedClipboardIsCheckedRemovesNothing() {
        let monitor = makeWatchingMonitor()
        pasteboard.copy("hunter2")
        monitor.poll()
        // Emptied while Safari is in front: the next look decides what that meant.
        pasteboard.clear()
        monitor.poll()

        // By then TextEdit is in front: the clipboard is not looked at again, and the entry stays.
        environment.frontmostApp = textEdit
        monitor.poll()
        environment.frontmostApp = safari
        monitor.poll()

        #expect(history.entries.map(\.text) == ["hunter2", "before"])
    }
}
