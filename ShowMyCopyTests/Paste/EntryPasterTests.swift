import Foundation
import Testing

@testable import ShowMyCopy

/// Records the waits the paster asks for and runs what a test wants to happen while it waits, such as a copy in
/// another app or the user switching apps. Never waits in real time.
@MainActor
final class PasteWait {
    private(set) var durations: [Duration] = []
    var meanwhile: @MainActor () -> Void = {}

    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] duration in
            await MainActor.run {
                durations.append(duration)
                meanwhile()
            }
        }
    }
}

@MainActor
struct EntryPasterTests {
    private let pasteboard = FakePasteboard()
    private let keystrokes = FakePasteKeystrokes(isAllowed: true)
    private let wait = PasteWait()
    private let textEdit = SourceApp(bundleIdentifier: "com.apple.TextEdit", name: "TextEdit")
    private let safari = SourceApp(bundleIdentifier: "com.apple.Safari", name: "Safari")
    private let ownBundleIdentifier = "com.example.ShowMyCopy"

    /// The app in front, as the paster sees it; tests change it as the user would.
    @MainActor
    private final class Front {
        var app: SourceApp?
        init(_ app: SourceApp?) { self.app = app }
    }

    private func makePaster(
        defaults: UserDefaults,
        front: Front
    ) -> (EntryPaster, PasteSettings) {
        let settings = PasteSettings.make(defaults: defaults, keystrokes: keystrokes)
        let paster = EntryPaster(
            pasteboard: pasteboard,
            keystrokes: keystrokes,
            settings: settings,
            frontmostApp: { front.app },
            ownBundleIdentifier: ownBundleIdentifier,
            sleep: wait.sleep
        )
        return (paster, settings)
    }

    /// The chosen entry was just written: its change count is the pasteboard's.
    private func copyChosenEntry() -> Int {
        pasteboard.write(.text("chosen"), concealed: false) ?? -1
    }

    @Test func pastesAfterGivingFocusBack() async throws {
        try await ContainerFactory.withDefaults { defaults in
            let (paster, _) = makePaster(defaults: defaults, front: Front(textEdit))
            let changeCount = copyChosenEntry()
            keystrokes.onPost = {
                // ⌘V goes out only after the wait, with the chosen entry still on the clipboard.
                #expect(wait.durations == [EntryPaster.focusDelay])
                #expect(pasteboard.changeCount == changeCount)
            }

            let outcome = await paster.paste(copiedAt: changeCount).value

            #expect(outcome == .pasted)
            #expect(keystrokes.postCount == 1)
        }
    }

    @Test func focusDelayIsShort() {
        // Long enough for the window server to give key focus back, short enough to feel immediate.
        #expect(EntryPaster.focusDelay == .milliseconds(100))
    }

    @Test func withoutPermissionOnlyCopiesAtOnceAndSaysSoOnce() async throws {
        try await ContainerFactory.withDefaults { defaults in
            keystrokes.isAllowed = false
            let (paster, settings) = makePaster(defaults: defaults, front: Front(textEdit))

            let outcome = await paster.paste(copiedAt: copyChosenEntry()).value

            #expect(outcome == .noAccess)
            #expect(keystrokes.postCount == 0)
            // Nothing to wait for, and the paste never asks macOS: only turning the setting on does.
            #expect(wait.durations.isEmpty)
            #expect(keystrokes.requestCount == 0)
            #expect(settings.access == .notGranted)
            #expect(paster.takeFallbackHint() == .noAccess)
            #expect(paster.takeFallbackHint() == nil)
        }
    }

    @Test func permissionTakenBackWhileTheWindowClosesOnlyCopies() async throws {
        try await ContainerFactory.withDefaults { defaults in
            let (paster, _) = makePaster(defaults: defaults, front: Front(textEdit))
            wait.meanwhile = { keystrokes.isAllowed = false }

            let outcome = await paster.paste(copiedAt: copyChosenEntry()).value

            #expect(outcome == .noAccess)
            #expect(keystrokes.postCount == 0)
            #expect(paster.takeFallbackHint() == .noAccess)
        }
    }

    @Test func somethingCopiedInBetweenIsNotPasted() async throws {
        try await ContainerFactory.withDefaults { defaults in
            let (paster, _) = makePaster(defaults: defaults, front: Front(textEdit))
            let changeCount = copyChosenEntry()
            wait.meanwhile = { pasteboard.copy("copied by another app") }

            let outcome = await paster.paste(copiedAt: changeCount).value

            #expect(outcome == .clipboardChanged)
            #expect(keystrokes.postCount == 0)
            // Not a problem with the permission: nothing to tell.
            #expect(paster.takeFallbackHint() == nil)
        }
    }

    @Test func aStaleChangeCountIsNotPasted() async throws {
        try await ContainerFactory.withDefaults { defaults in
            let (paster, _) = makePaster(defaults: defaults, front: Front(textEdit))
            let changeCount = copyChosenEntry()
            pasteboard.copy("copied right after")

            #expect(await paster.paste(copiedAt: changeCount).value == .clipboardChanged)
            #expect(keystrokes.postCount == 0)
        }
    }

    @Test func switchingAppsMeanwhileIsNotPastedInto() async throws {
        try await ContainerFactory.withDefaults { defaults in
            let front = Front(textEdit)
            let (paster, _) = makePaster(defaults: defaults, front: front)
            wait.meanwhile = { front.app = safari }

            #expect(await paster.paste(copiedAt: copyChosenEntry()).value == .appChanged)
            #expect(keystrokes.postCount == 0)
        }
    }

    /// With Settings in front, the history window closes onto this app: ⌘V would paste into Settings.
    @Test func neverPastesIntoThisApp() async throws {
        try await ContainerFactory.withDefaults { defaults in
            let showMyCopy = SourceApp(bundleIdentifier: ownBundleIdentifier, name: "Show My Copy")
            let (paster, _) = makePaster(defaults: defaults, front: Front(showMyCopy))

            #expect(await paster.paste(copiedAt: copyChosenEntry()).value == .appChanged)
            #expect(keystrokes.postCount == 0)
        }
    }

    @Test func noAppInFrontIsNotPastedInto() async throws {
        try await ContainerFactory.withDefaults { defaults in
            let (paster, _) = makePaster(defaults: defaults, front: Front(nil))

            #expect(await paster.paste(copiedAt: copyChosenEntry()).value == .appChanged)
            #expect(keystrokes.postCount == 0)
        }
    }

    @Test func eventsThatCannotBeMadeOnlyCopyAndSaySo() async throws {
        try await ContainerFactory.withDefaults { defaults in
            keystrokes.postSucceeds = false
            let (paster, _) = makePaster(defaults: defaults, front: Front(textEdit))

            #expect(await paster.paste(copiedAt: copyChosenEntry()).value == .couldNotPost)
            #expect(paster.takeFallbackHint() == .couldNotPost)
        }
    }

    /// The paster compares change counts only: it never reads what is on the clipboard, a password included.
    @Test func neverReadsTheClipboard() async throws {
        try await ContainerFactory.withDefaults { defaults in
            let (paster, _) = makePaster(defaults: defaults, front: Front(textEdit))
            let changeCount = pasteboard.write(.text("hunter2"), concealed: true) ?? -1

            #expect(await paster.paste(copiedAt: changeCount).value == .pasted)
            #expect(pasteboard.typesReadCount == 0)
            #expect(pasteboard.stringReadCount == 0)
            #expect(pasteboard.dataReadCount == 0)
        }
    }

    @Test func aSuccessfulPasteMakesAFutureProblemToldAgain() async throws {
        try await ContainerFactory.withDefaults { defaults in
            let (paster, settings) = makePaster(defaults: defaults, front: Front(textEdit))
            settings.pasteFellBack(.noAccess)
            _ = paster.takeFallbackHint()

            #expect(await paster.paste(copiedAt: copyChosenEntry()).value == .pasted)
            keystrokes.isAllowed = false
            #expect(await paster.paste(copiedAt: copyChosenEntry()).value == .noAccess)

            #expect(paster.takeFallbackHint() == .noAccess)
        }
    }
}
