import Foundation
import Testing

@testable import ShowMyCopy

/// Settings → General → Paste after choosing an entry, and what it says about macOS's permission to paste.
@MainActor
struct PasteSettingsTests {
    @Test func offByDefaultWithoutAskingMacOS() throws {
        try TestDefaults.with { defaults in
            let keystrokes = FakePasteKeystrokes()
            let settings = PasteSettings.make(defaults: defaults, keystrokes: keystrokes)

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
            let settings = PasteSettings.make(defaults: defaults, keystrokes: keystrokes)

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
            let settings = PasteSettings.make(defaults: defaults, keystrokes: keystrokes)

            settings.setOn(true)

            #expect(settings.access == .granted)
            #expect(!settings.needsAccess)
        }
    }

    @Test func turningOnWhenAlreadyAllowedDoesNotAsk() throws {
        try TestDefaults.with { defaults in
            let keystrokes = FakePasteKeystrokes(isAllowed: true)
            let settings = PasteSettings.make(defaults: defaults, keystrokes: keystrokes)

            settings.setOn(true)

            #expect(keystrokes.requestCount == 0)
            #expect(settings.access == .granted)
        }
    }

    /// Only the user can take the permission back, in System Settings; Settings keep saying the app has it.
    @Test func turningOffNeverAsksAndKeepsShowingThePermission() throws {
        try TestDefaults.with { defaults in
            let keystrokes = FakePasteKeystrokes(isAllowed: true)
            let settings = PasteSettings.make(defaults: defaults, keystrokes: keystrokes)
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
            let settings = PasteSettings.make(defaults: defaults, keystrokes: keystrokes)

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
            PasteSettings.make(defaults: defaults, keystrokes: keystrokes).setOn(true)

            let relaunched = PasteSettings.make(defaults: defaults, keystrokes: keystrokes)

            #expect(relaunched.isOn)
            #expect(defaults.bool(forKey: SettingsKey.pasteAfterChoosing))
        }
    }

    @Test func refreshShowsAPermissionTakenBackOrGivenInSystemSettings() throws {
        try TestDefaults.with { defaults in
            let keystrokes = FakePasteKeystrokes(isAllowed: true)
            let settings = PasteSettings.make(defaults: defaults, keystrokes: keystrokes)
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

    /// macOS shows its own alert only the first time the app asks. After that the button under the setting opens
    /// Privacy & Security → Accessibility, where the user allows the app, and asks macOS nothing.
    @Test func theButtonOpensSystemSettingsWithoutAskingAgain() throws {
        try TestDefaults.with { defaults in
            let keystrokes = FakePasteKeystrokes()
            let systemSettings = FakeAccessibilitySettings()
            let settings = PasteSettings.make(
                defaults: defaults, keystrokes: keystrokes, systemSettings: systemSettings)
            settings.setOn(true)
            #expect(settings.needsAccess)

            settings.openAccessibilitySettings()

            #expect(systemSettings.openCount == 1)
            #expect(keystrokes.requestCount == 1)
            // The user allows the app there; Settings show it when they come to the front again.
            keystrokes.isAllowed = true
            settings.refresh()
            #expect(!settings.needsAccess)
            #expect(systemSettings.openCount == 1)
        }
    }

    /// Turning the setting on leaves the first step to macOS's own alert: System Settings open only from the button.
    @Test func turningOnDoesNotOpenSystemSettings() throws {
        try TestDefaults.with { defaults in
            let systemSettings = FakeAccessibilitySettings()
            let settings = PasteSettings.make(
                defaults: defaults, keystrokes: FakePasteKeystrokes(), systemSettings: systemSettings)

            settings.setOn(true)
            settings.refresh()
            #expect(!settings.checkAccess())
            settings.setOn(false)

            #expect(systemSettings.openCount == 0)
        }
    }

    @Test func fallbackIsToldOnce() throws {
        try TestDefaults.with { defaults in
            let settings = PasteSettings.make(defaults: defaults, keystrokes: FakePasteKeystrokes())

            #expect(settings.takeFallbackHint() == nil)
            settings.pasteFellBack(.noAccess)
            #expect(settings.takeFallbackHint() == .noAccess)
            #expect(settings.takeFallbackHint() == nil)

            // Told once: later fallbacks, also after a relaunch, are not told again.
            settings.pasteFellBack(.couldNotPost)
            #expect(settings.takeFallbackHint() == nil)
            let relaunched = PasteSettings.make(defaults: defaults, keystrokes: FakePasteKeystrokes())
            relaunched.pasteFellBack(.noAccess)
            #expect(relaunched.takeFallbackHint() == nil)
        }
    }

    /// Once the app may paste again, a later problem, such as the user taking the permission back, is told again.
    @Test func fallbackIsToldAgainAfterTheAppCouldPaste() throws {
        try TestDefaults.with { defaults in
            let keystrokes = FakePasteKeystrokes()
            let settings = PasteSettings.make(defaults: defaults, keystrokes: keystrokes)
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
