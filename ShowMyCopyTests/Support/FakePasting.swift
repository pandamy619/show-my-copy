import Foundation

@testable import ShowMyCopy

/// Stands in for Core Graphics: keeps whether the app may post key events, as the user sets it in System Settings,
/// and counts the ⌘V presses it was asked to post. It starts as a fresh install: not allowed.
@MainActor
final class FakePasteKeystrokes: PasteAccessChecking, PasteKeystrokePosting {
    /// What macOS says now; tests change it as the user would in Privacy & Security.
    var isAllowed: Bool
    /// What the user answers when macOS asks: true allows the app.
    var allowsWhenAsked = false
    /// When false, the key events cannot be made.
    var postSucceeds = true
    /// Runs when ⌘V is posted, for example to check what is on the pasteboard then.
    var onPost: @MainActor () -> Void = {}
    private(set) var checkCount = 0
    private(set) var requestCount = 0
    private(set) var postCount = 0

    init(isAllowed: Bool = false) {
        self.isAllowed = isAllowed
    }

    func isGranted() -> Bool {
        checkCount += 1
        return isAllowed
    }

    func request() -> Bool {
        requestCount += 1
        if allowsWhenAsked {
            isAllowed = true
        }
        return isAllowed
    }

    func postPaste() -> Bool {
        guard postSucceeds else {
            return false
        }
        postCount += 1
        onPost()
        return true
    }
}

/// Stands in for System Settings: counts how often the app opened Privacy & Security → Accessibility.
@MainActor
final class FakeAccessibilitySettings: AccessibilitySettingsOpening {
    private(set) var openCount = 0

    func openAccessibilityList() {
        openCount += 1
    }
}

extension PasteSettings {
    /// The paste setting over `keystrokes`, as the user sets it in System Settings, and `systemSettings`, which only
    /// count how often they were opened.
    static func make(
        defaults: UserDefaults,
        keystrokes: FakePasteKeystrokes,
        systemSettings: FakeAccessibilitySettings = FakeAccessibilitySettings()
    ) -> PasteSettings {
        PasteSettings(defaults: defaults, accessChecker: keystrokes, accessibilitySettings: systemSettings)
    }
}

/// Records what the history window asked to paste, without pasting.
@MainActor
final class EntryPasterSpy: EntryPasting {
    private(set) var pastedChangeCounts: [Int] = []
    /// What `takeFallbackHint()` returns next, once.
    var fallbackHint: PasteFallback?

    func paste(copiedAt changeCount: Int) -> Task<PasteOutcome, Never> {
        pastedChangeCounts.append(changeCount)
        return Task { .pasted }
    }

    func takeFallbackHint() -> PasteFallback? {
        defer { fallbackHint = nil }
        return fallbackHint
    }
}

extension AppServices.Paste {
    /// Not allowed to paste unless `keystrokes` says so, posting nothing, waiting no time, and System Settings that
    /// only count how often they were opened.
    @MainActor
    static func fake(
        _ keystrokes: FakePasteKeystrokes? = nil, systemSettings: FakeAccessibilitySettings? = nil
    ) -> AppServices.Paste {
        let keystrokes = keystrokes ?? FakePasteKeystrokes()
        return AppServices.Paste(
            access: keystrokes,
            keystrokes: keystrokes,
            systemSettings: systemSettings ?? FakeAccessibilitySettings(),
            sleep: { _ in }
        )
    }
}
