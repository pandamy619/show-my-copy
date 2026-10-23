# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub: **Security → Report a vulnerability** in this repository. Do not open a public issue, and do not include real clipboard contents or passwords in the report.

## Supported versions

There are no releases yet. Security fixes go to the `main` branch; once releases exist, only the latest one will get them.

## Security model

### Today (0.1)

- **No network.** The app is sandboxed without network entitlements, so macOS blocks any connection it tries to make. CI builds the Release configuration with ad-hoc signing and checks its signed entitlements (`make security`).
- **Stored on this Mac only.** The history is saved in the app's sandbox container (`~/Library/Containers/…/Data/Library/Application Support/ShowMyCopy/History.store`, a SwiftData/SQLite store) so it survives quitting the app. It is never synced (no CloudKit) or sent anywhere, and the folder is excluded from Time Machine and other backups. Clear History in Settings deletes it from disk as well; removed and expired entries are deleted from disk right away.
- **Saved passwords are encrypted on disk.** A concealed entry is encrypted with a key kept in your Keychain before it is written, padded so its size does not tell the password's length. No hash or preview of a password is stored: a plain hash of a short password could be checked against a list of common passwords. A saved password that cannot be decrypted (the key is gone or the data was changed) is deleted at launch. If the Keychain cannot be used, passwords are kept in memory only and everything else is still saved.
- **Passwords are not kept by default.** Items marked as concealed (see [nspasteboard.org](http://nspasteboard.org)) or with the older markers some password managers use, and anything copied while a known password manager is the frontmost app (1Password, Bitwarden, Passwords, Keychain Access, KeePassXC, Strongbox, LastPass, Proton Pass, Enpass, Keeper), are not recorded, and their text is not read. Items marked as transient or auto-generated are never stored.
- **Cleared passwords leave the history.** Password managers empty the clipboard a while after copying a password. When the clipboard is emptied within 3 minutes of a copy that is still on it, that entry is removed, or hidden with an expiry if you save passwords.
- **Saving passwords is opt-in.** With Settings → Passwords → Save passwords on, passwords are kept masked in the history (the mask does not show their length), revealed one row at a time with the eye button and hidden again when the window closes, left out of text search, never read out by VoiceOver, and removed after 1 minute, 10 minutes (default) or 1 hour. Turning the setting off removes them at once. A password copied back from the history is marked as concealed and kept off Universal Clipboard, so other clipboard managers and your other devices do not get it.
- **Saved passwords are encrypted on disk.** When history is saved on disk and Save passwords is on, each password is encrypted with AES-256-GCM before it is written. The key is created on this Mac, kept in your Keychain and never synced to iCloud. If the key cannot be read, for example because you deny Show My Copy access to it, passwords are kept in memory only, and passwords saved before can no longer be opened and are removed.
- **Minimal permissions.** The app asks for no permissions: no Accessibility, no Input Monitoring.
- **No secrets in logs.** Clipboard contents are never logged.

### Known limitations

- **Some unmarked passwords are kept.** A password copied without a marker from an app that is not a known password manager — for example from a browser extension or a text file — is kept like any other text, unless a password manager empties the clipboard within 3 minutes. The same rule can remove an ordinary entry when an app empties the clipboard soon after you copy it.
- **The first copy after launch, sleep or unlock** has no known source app, so only markers tell whether it is a password.
- **Saved passwords are plain text in memory** while they are kept; the mask only hides them on screen.
- **Where the encryption key is kept.** The app has no keychain entitlement, so macOS does not let it use the keychain that keeps an item on one Mac only and readable only while the Mac is unlocked. The key is kept in your login keychain instead: Time Machine backs it up, and Migration Assistant can move it to a new Mac together with the history. When the app's code signature changes, for example in a copy you built yourself, macOS asks whether Show My Copy may use the key.
- **Deleted entries may stay on the disk for a while.** The history is an SQLite database. When an entry is deleted, cleared or turned into a password, SQLite marks its old data as free space but does not overwrite it, so it can remain in the database file and in free disk blocks until it is overwritten. FileVault protects it while the Mac is off or locked. Passwords are written to disk only encrypted, so this applies to their encrypted form only, unless an entry was saved as normal text before it was recognized as a password.
- **Some details of saved passwords are not encrypted:** when they were copied, from which app, and when they expire.
- **A damaged history file is kept aside.** If the history file cannot be opened, it is renamed to `History.store.damaged` (replacing an older one) in the same folder, and a new, empty history starts.
- **Password manager list.** Some bundle identifiers (Proton Pass, Keeper, LastPass, Enpass, Strongbox Pro) are taken from third-party catalogs and still have to be checked on a Mac; Dashlane and NordPass are not listed yet.
- **Screen sharing.** The history window uses the standard macOS opt-out from screen sharing, screenshots and screen recordings. Some newer capture methods (ScreenCaptureKit on recent macOS versions) may still capture it.

### Planned

- Paste into the active app. Accessibility will be requested only if you turn this on.
- Releases, with CI checking the signed entitlements of every release build.
