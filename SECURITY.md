# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub: **Security → Report a vulnerability** in this repository. Do not open a public issue, and do not include real clipboard contents or passwords in the report.

## Supported versions

There are no releases yet. Security fixes go to the `main` branch; once releases exist, only the latest one will get them.

## Security model

### Today (0.1)

- **No network.** The app is sandboxed without network entitlements, so macOS blocks any connection it tries to make. CI builds the Release configuration with ad-hoc signing and checks its signed entitlements (`make security`).
- **Memory only.** History is kept in memory and is lost when you quit the app. Nothing is written to disk or sent anywhere.
- **Passwords are not kept by default.** Items marked as concealed (see [nspasteboard.org](http://nspasteboard.org)) or with the older markers some password managers use, and anything copied while a known password manager is the frontmost app (1Password, Bitwarden, Passwords, Keychain Access, KeePassXC, Strongbox, LastPass, Proton Pass, Enpass, Keeper), are not recorded, and their text is not read. Items marked as transient or auto-generated are never stored.
- **Cleared passwords leave the history.** Password managers empty the clipboard a while after copying a password. When the clipboard is emptied within 3 minutes of a copy that is still on it, that entry is removed, or hidden with an expiry if you save passwords.
- **Saving passwords is opt-in.** With Settings → Passwords → Save passwords on, passwords are kept masked in the history (the mask does not show their length), revealed one row at a time with the eye button and hidden again when the window closes, left out of text search, never read out by VoiceOver, and removed after 1 minute, 10 minutes (default) or 1 hour. Turning the setting off removes them at once. A password copied back from the history is marked as concealed and kept off Universal Clipboard, so other clipboard managers and your other devices do not get it.
- **Minimal permissions.** The app asks for no permissions: no Accessibility, no Input Monitoring.
- **No secrets in logs.** Clipboard contents are never logged.

### Known limitations

- **Some unmarked passwords are kept.** A password copied without a marker from an app that is not a known password manager — for example from a browser extension or a text file — is kept like any other text, unless a password manager empties the clipboard within 3 minutes. The same rule can remove an ordinary entry when an app empties the clipboard soon after you copy it.
- **The first copy after launch, sleep or unlock** has no known source app, so only markers tell whether it is a password.
- **Saved passwords are plain text in memory** while they are kept; the mask only hides them on screen.
- **Password manager list.** Some bundle identifiers (Proton Pass, Keeper, LastPass, Enpass, Strongbox Pro) are taken from third-party catalogs and still have to be checked on a Mac; Dashlane and NordPass are not listed yet.
- **Screen sharing.** The history window uses the standard macOS opt-out from screen sharing, screenshots and screen recordings. Some newer capture methods (ScreenCaptureKit on recent macOS versions) may still capture it.

### Planned

- History saved on disk in the app container, so it survives a restart.
- Saved passwords encrypted on disk with a key kept in your Keychain, once history is saved on disk.
- Paste into the active app. Accessibility will be requested only if you turn this on.
- Releases, with CI checking the signed entitlements of every release build.
