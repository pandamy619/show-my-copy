Show My Copy is a clipboard history app. No account or sign-in is needed.

HOW TO USE IT
The app has no Dock or menu bar icon (LSUIElement). Settings open at first launch. Press Option-Command-V to open the history over any app; Return copies the selected entry back, Escape closes. To reopen Settings, open the app again or press Command-, in the history window. On macOS 26, Control Center can show a Clipboard History button (a WidgetKit extension) that opens the same window.

CLIPBOARD MONITORING
Recording what the user copies is the app's purpose. It checks the general pasteboard's change count twice a second (less often under App Nap) and reads a new item only after it changes. It skips items marked concealed, transient or auto-generated, anything copied while a known password manager or an app the user excluded is in front, and pauses while the Mac sleeps or the screen is locked. History stays in the app's container, excluded from backups, and is removed after 8 hours by default.

SANDBOX
App Sandbox and Hardened Runtime are on for the app and the extension. The app's only other entitlement is com.apple.security.files.user-selected.read-only, used by Settings > Excluded apps > Choose an App... (an open panel limited to apps) to read the chosen app's bundle identifier and name. The extension has only the sandbox entitlement. No temporary exceptions.

NO NETWORK
No network entitlements, no networking code, no analytics, ads or crash reporting. Nothing leaves the Mac. The privacy manifest declares no tracking and no collected data.

OPTIONAL PASTE (PostEvent permission)
Settings > General > "Paste after choosing an entry" is OFF by default. Only when the user turns it on does the app call CGRequestPostEventAccess, which macOS lists under Privacy & Security > Accessibility. With it allowed, choosing an entry with Return copies it, closes the window and, about 0.1 s later, posts one Command-V (key down and up) to the app that was in front, only if the clipboard still holds that entry and the same app is still in front. That is the only event it posts, and only after the user chose an entry. It does not use the rest of the Accessibility API (AXIsProcessTrusted, AXUIElement), event taps or monitors, and never asks for Input Monitoring. Without the permission, Return only copies.
To test: turn the setting on, allow the app in System Settings, open TextEdit, press Option-Command-V, choose an entry, press Return.
Guideline 2.4.5(i) asks Mac App Store apps to be appropriately sandboxed. The app is, and this feature uses the public CGRequestPostEventAccess and CGEvent.post(tap:) APIs inside the sandbox, with no entitlement or exception. We are not aware of a guideline that rules it out, but if you consider it inappropriate for the Mac App Store, please tell us: we will ship the store build without the feature.

OPEN AT LOGIN
Off by default, per 2.4.5(iii). Settings > General > Open at login registers SMAppService.mainApp only when the user turns it on; no helper app or launch agent.

KEYCHAIN
Passwords are not saved by default. If the user turns on Settings > Passwords > Save passwords, they are encrypted with AES-GCM (CryptoKit) and the key is kept in the user's keychain. Nothing else uses the Keychain.

Privacy policy: https://github.com/pandamy619/ShowMyCopy/blob/main/PRIVACY.md
