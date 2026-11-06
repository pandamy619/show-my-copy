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
    private let window = HistoryWindowState()
    private let timing = PasteTiming.standard

    /// The app in front, as the paster sees it; tests change it as the user would.
    @MainActor
    private final class Front {
        var app: SourceApp?
        init(_ app: SourceApp?) { self.app = app }
    }

    /// What the paster reads for the next paste, as debug overrides change it.
    @MainActor
    private final class CurrentTuning {
        var value = PasteTuning.standard
    }

    /// Whether the window server still shows the history window; tests change it as it fades out or opens again.
    @MainActor
    private final class HistoryWindowState {
        var isGone = true
        private(set) var checkCount = 0

        func check() -> Bool {
            checkCount += 1
            return isGone
        }
    }

    private func makePaster(
        defaults: UserDefaults,
        front: Front,
        tuning: @escaping @MainActor () -> PasteTuning = { .standard }
    ) -> (EntryPaster, PasteSettings) {
        let settings = PasteSettings.make(defaults: defaults, keystrokes: keystrokes)
        let paster = EntryPaster(
            pasteboard: pasteboard,
            keystrokes: keystrokes,
            settings: settings,
            frontmostApp: { front.app },
            ownBundleIdentifier: ownBundleIdentifier,
            sleep: wait.sleep,
            tuning: tuning
        )
        return (paster, settings)
    }

    /// Pastes as the history window does right after it was told to close.
    private func paste(_ paster: EntryPaster, copiedAt changeCount: Int) async -> PasteOutcome {
        await paster.paste(copiedAt: changeCount) { [window] in window.check() }.value
    }

    /// The chosen entry was just written: its change count is the pasteboard's.
    private func copyChosenEntry() -> Int {
        pasteboard.write(.text("chosen"), concealed: false) ?? -1
    }

    @Test func pastesOnceTheWindowIsGoneAndTheAppHadTimeToFocus() async throws {
        try await ContainerFactory.withDefaults { defaults in
            let (paster, _) = makePaster(defaults: defaults, front: Front(textEdit))
            let changeCount = copyChosenEntry()
            keystrokes.onPost = {
                // ⌘V goes out only after the settle wait, with the chosen entry still on the clipboard.
                #expect(wait.durations == [timing.settleDelay])
                #expect(pasteboard.changeCount == changeCount)
            }

            let outcome = await paste(paster, copiedAt: changeCount)

            #expect(outcome == .pasted)
            #expect(keystrokes.postedStyles == [.standard])
        }
    }

    /// The panel can stay on screen for a moment after it was ordered out, while it fades out.
    @Test func waitsWhileTheWindowIsStillOnScreen() async throws {
        try await ContainerFactory.withDefaults { defaults in
            let (paster, _) = makePaster(defaults: defaults, front: Front(textEdit))
            window.isGone = false
            wait.meanwhile = {
                if wait.durations.count == 3 {
                    window.isGone = true
                }
            }

            let outcome = await paste(paster, copiedAt: copyChosenEntry())

            #expect(outcome == .pasted)
            let poll = timing.pollInterval
            #expect(wait.durations == [poll, poll, poll, timing.settleDelay])
        }
    }

    @Test func aWindowThatStaysOnScreenIsNotPastedIntoAndTheWaitEnds() async throws {
        try await ContainerFactory.withDefaults { defaults in
            let (paster, _) = makePaster(defaults: defaults, front: Front(textEdit))
            window.isGone = false

            let outcome = await paste(paster, copiedAt: copyChosenEntry())

            #expect(outcome == .historyWindowOpen)
            #expect(keystrokes.postCount == 0)
            #expect(wait.durations.reduce(.zero, +) == timing.longestWait)
            #expect(wait.durations.last == timing.settleDelay)
            // Not a problem with the permission: nothing to tell.
            #expect(paster.takeFallbackHint() == nil)
        }
    }

    /// The user can press the history shortcut again right after choosing: ⌘V would land in the search field.
    @Test func aWindowOpenedAgainMeanwhileIsNotPastedInto() async throws {
        try await ContainerFactory.withDefaults { defaults in
            let (paster, _) = makePaster(defaults: defaults, front: Front(textEdit))
            wait.meanwhile = { window.isGone = false }

            #expect(await paste(paster, copiedAt: copyChosenEntry()) == .historyWindowOpen)
            #expect(keystrokes.postCount == 0)
        }
    }

    /// A cancelled sleep throws at once. The wait still ends after as many checks as the real one makes, and the
    /// checks before ⌘V still decide.
    @Test func aCancelledWaitEndsAndStillChecks() async throws {
        try await ContainerFactory.withDefaults { defaults in
            let settings = PasteSettings.make(defaults: defaults, keystrokes: keystrokes)
            let textEdit = textEdit
            let paster = EntryPaster(
                pasteboard: pasteboard,
                keystrokes: keystrokes,
                settings: settings,
                frontmostApp: { textEdit },
                ownBundleIdentifier: ownBundleIdentifier,
                sleep: { _ in throw CancellationError() },
                tuning: { .standard }
            )
            window.isGone = false

            #expect(await paste(paster, copiedAt: copyChosenEntry()) == .historyWindowOpen)
            let checksWhileWaiting = Int(timing.longestWaitForWindow / timing.pollInterval)
            // Every check while waiting, the last one when the wait ran out, and the one before ⌘V.
            #expect(window.checkCount == checksWhileWaiting + 2)

            window.isGone = true
            #expect(await paste(paster, copiedAt: copyChosenEntry()) == .pasted)
        }
    }

    @Test func eachPasteUsesTheTuningReadForIt() async throws {
        try await ContainerFactory.withDefaults { defaults in
            var tuning = PasteTuning.standard
            tuning.timing.settleDelay = .milliseconds(300)
            tuning.style = PastePostingStyle(pressesCommandKey: false, carriesText: false, tap: .annotatedSession)
            let current = CurrentTuning()
            let (paster, _) = makePaster(defaults: defaults, front: Front(textEdit), tuning: { current.value })

            #expect(await paste(paster, copiedAt: copyChosenEntry()) == .pasted)
            current.value = tuning
            #expect(await paste(paster, copiedAt: copyChosenEntry()) == .pasted)

            #expect(wait.durations == [timing.settleDelay, .milliseconds(300)])
            #expect(keystrokes.postedStyles == [.standard, tuning.style])
        }
    }

    @Test func withoutPermissionOnlyCopiesAtOnceAndSaysSoOnce() async throws {
        try await ContainerFactory.withDefaults { defaults in
            keystrokes.isAllowed = false
            let (paster, settings) = makePaster(defaults: defaults, front: Front(textEdit))

            let outcome = await paste(paster, copiedAt: copyChosenEntry())

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

            let outcome = await paste(paster, copiedAt: copyChosenEntry())

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

            let outcome = await paste(paster, copiedAt: changeCount)

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

            #expect(await paste(paster, copiedAt: changeCount) == .clipboardChanged)
            #expect(keystrokes.postCount == 0)
        }
    }

    @Test func switchingAppsMeanwhileIsNotPastedInto() async throws {
        try await ContainerFactory.withDefaults { defaults in
            let front = Front(textEdit)
            let (paster, _) = makePaster(defaults: defaults, front: front)
            wait.meanwhile = { front.app = safari }

            #expect(await paste(paster, copiedAt: copyChosenEntry()) == .appChanged)
            #expect(keystrokes.postCount == 0)
        }
    }

    /// With Settings in front, the history window closes onto this app: ⌘V would paste into Settings.
    @Test func neverPastesIntoThisApp() async throws {
        try await ContainerFactory.withDefaults { defaults in
            let showMyCopy = SourceApp(bundleIdentifier: ownBundleIdentifier, name: "Show My Copy")
            let (paster, _) = makePaster(defaults: defaults, front: Front(showMyCopy))

            #expect(await paste(paster, copiedAt: copyChosenEntry()) == .appChanged)
            #expect(keystrokes.postCount == 0)
        }
    }

    @Test func noAppInFrontIsNotPastedInto() async throws {
        try await ContainerFactory.withDefaults { defaults in
            let (paster, _) = makePaster(defaults: defaults, front: Front(nil))

            #expect(await paste(paster, copiedAt: copyChosenEntry()) == .appChanged)
            #expect(keystrokes.postCount == 0)
        }
    }

    @Test func eventsThatCannotBeMadeOnlyCopyAndSaySo() async throws {
        try await ContainerFactory.withDefaults { defaults in
            keystrokes.postSucceeds = false
            let (paster, _) = makePaster(defaults: defaults, front: Front(textEdit))

            #expect(await paste(paster, copiedAt: copyChosenEntry()) == .couldNotPost)
            #expect(paster.takeFallbackHint() == .couldNotPost)
        }
    }

    /// The paster compares change counts only: it never reads what is on the clipboard, a password included.
    @Test func neverReadsTheClipboard() async throws {
        try await ContainerFactory.withDefaults { defaults in
            let (paster, _) = makePaster(defaults: defaults, front: Front(textEdit))
            let changeCount = pasteboard.write(.text("hunter2"), concealed: true) ?? -1

            #expect(await paste(paster, copiedAt: changeCount) == .pasted)
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

            #expect(await paste(paster, copiedAt: copyChosenEntry()) == .pasted)
            keystrokes.isAllowed = false
            #expect(await paste(paster, copiedAt: copyChosenEntry()) == .noAccess)

            #expect(paster.takeFallbackHint() == .noAccess)
        }
    }
}
