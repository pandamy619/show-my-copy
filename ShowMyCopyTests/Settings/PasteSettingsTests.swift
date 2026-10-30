import Foundation
import Testing

@testable import ShowMyCopy

/// Settings → General → Paste after choosing an entry, and what it says about macOS's permission to paste.
@MainActor
struct PasteSettingsTests {
    @Test func offByDefaultWithoutAskingMacOS() throws {
        try TestDefaults.with { defaults in
            let keystrokes = FakePasteKeystrokes()
            let settings = PasteSettings(defaults: defaults, accessChecker: keystrokes)

            #expect(!settings.isOn)
            #expect(settings.access == nil)
            #expect(!settings.needsAccess)
            #expect(keystrokes.checkCount == 0)
            #expect(keystrokes.requestCount == 0)
        }
    }

    @Test func turningOnAsksMacOSAndShowsTheAnswer() throws {
        try TestDefaults.with { defaults in
            let keystrokes = FakePasteKeystrokes()
            let settings = PasteSettings(defaults: defaults, accessChecker: keystrokes)

            settings.setOn(true)

            #expect(settings.isOn)
            #expect(keystrokes.requestCount == 1)
            // The user did not allow it (yet): Settings say Return only copies.
            #expect(settings.access == .notGranted)
            #expect(settings.needsAccess)
        }
    }

    @Test func turningOnWhenTheUserAllowsIt() throws {
        try TestDefaults.with { defaults in
            let keystrokes = FakePasteKeystrokes()
            keystrokes.allowsWhenAsked = true
            let settings = PasteSettings(defaults: defaults, accessChecker: keystrokes)

            settings.setOn(true)

            #expect(settings.access == .granted)
            #expect(!settings.needsAccess)
        }
    }

    @Test func turningOnWhenAlreadyAllowedDoesNotAsk() throws {
        try TestDefaults.with { defaults in
            let keystrokes = FakePasteKeystrokes(isAllowed: true)
            let settings = PasteSettings(defaults: defaults, accessChecker: keystrokes)

            settings.setOn(true)

            #expect(keystrokes.requestCount == 0)
            #expect(settings.access == .granted)
        }
    }

    /// Only the user can take the permission back, in System Settings; Settings keep saying the app has it.
    @Test func turningOffNeverAsksAndKeepsShowingThePermission() throws {
        try TestDefaults.with { defaults in
            let keystrokes = FakePasteKeystrokes(isAllowed: true)
            let settings = PasteSettings(defaults: defaults, accessChecker: keystrokes)
            settings.setOn(true)

            settings.setOn(false)

            #expect(!settings.isOn)
            #expect(settings.access == .granted)
            #expect(keystrokes.requestCount == 0)
        }
    }

    @Test func neverAsksWhileOff() throws {
        try TestDefaults.with { defaults in
            let keystrokes = FakePasteKeystrokes()
            let settings = PasteSettings(defaults: defaults, accessChecker: keystrokes)

            settings.refresh()
            #expect(!settings.checkAccess())
            settings.setOn(false)

            #expect(keystrokes.requestCount == 0)
            #expect(settings.access == .notGranted)
            // Off: nothing to warn about.
            #expect(!settings.needsAccess)
        }
    }

    @Test func choiceIsSavedForTheNextLaunch() throws {
        try TestDefaults.with { defaults in
            let keystrokes = FakePasteKeystrokes(isAllowed: true)
            PasteSettings(defaults: defaults, accessChecker: keystrokes).setOn(true)

            let relaunched = PasteSettings(defaults: defaults, accessChecker: keystrokes)

            #expect(relaunched.isOn)
            #expect(defaults.bool(forKey: SettingsKey.pasteAfterChoosing))
        }
    }

    @Test func refreshShowsAPermissionTakenBackOrGivenInSystemSettings() throws {
        try TestDefaults.with { defaults in
            let keystrokes = FakePasteKeystrokes(isAllowed: true)
            let settings = PasteSettings(defaults: defaults, accessChecker: keystrokes)
            settings.setOn(true)

            keystrokes.isAllowed = false
            settings.refresh()
            #expect(settings.needsAccess)

            keystrokes.isAllowed = true
            settings.refresh()
            #expect(!settings.needsAccess)
            #expect(keystrokes.requestCount == 0)
        }
    }

    @Test func askingAgainShowsTheAnswer() throws {
        try TestDefaults.with { defaults in
            let keystrokes = FakePasteKeystrokes()
            let settings = PasteSettings(defaults: defaults, accessChecker: keystrokes)
            settings.setOn(true)
            #expect(settings.needsAccess)

            keystrokes.allowsWhenAsked = true
            settings.requestAccess()

            #expect(keystrokes.requestCount == 2)
            #expect(settings.access == .granted)
        }
    }

    @Test func fallbackIsToldOnce() throws {
        try TestDefaults.with { defaults in
            let settings = PasteSettings(defaults: defaults, accessChecker: FakePasteKeystrokes())

            #expect(settings.takeFallbackHint() == nil)
            settings.pasteFellBack(.noAccess)
            #expect(settings.takeFallbackHint() == .noAccess)
            #expect(settings.takeFallbackHint() == nil)

            // Told once: later fallbacks, also after a relaunch, are not told again.
            settings.pasteFellBack(.couldNotPost)
            #expect(settings.takeFallbackHint() == nil)
            let relaunched = PasteSettings(defaults: defaults, accessChecker: FakePasteKeystrokes())
            relaunched.pasteFellBack(.noAccess)
            #expect(relaunched.takeFallbackHint() == nil)
        }
    }

    /// Once the app may paste again, a later problem, such as the user taking the permission back, is told again.
    @Test func fallbackIsToldAgainAfterTheAppCouldPaste() throws {
        try TestDefaults.with { defaults in
            let keystrokes = FakePasteKeystrokes()
            let settings = PasteSettings(defaults: defaults, accessChecker: keystrokes)
            settings.pasteFellBack(.noAccess)
            _ = settings.takeFallbackHint()

            keystrokes.isAllowed = true
            #expect(settings.checkAccess())
            keystrokes.isAllowed = false
            settings.pasteFellBack(.noAccess)

            #expect(settings.takeFallbackHint() == .noAccess)
        }
    }
}
