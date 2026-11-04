/// Opens System Settings at Privacy & Security → Accessibility, where the user allows Show My Copy to paste, or takes
/// that back. macOS shows its own alert only the first time the app asks (`PasteAccessChecking.request()`); after
/// that, this list is the only place where the user can allow it.
///
/// It takes nothing: the place it opens is fixed, so nothing the user copied can reach another app this way. The real
/// one is `SystemSettingsPane`, the only file allowed to open anything (SECURITY.md); tests use a fake.
@MainActor
protocol AccessibilitySettingsOpening: AnyObject {
    func openAccessibilityList()
}
