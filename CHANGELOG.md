# Changelog

## [Unreleased]

First version, 0.1.0. Not released yet.

- Clipboard history of text in the background, with the app it was copied from.
- History survives quitting the app: it is saved on your Mac only, in the app's sandbox container, never synced and left out of Time Machine backups. Saved passwords are encrypted with a key kept in your Keychain; without Keychain access they are kept in memory only.
- History window on a global shortcut (⌥⌘V by default, changeable in Settings), on top of any app.
- Search, arrow keys to select, Enter to copy an entry back, Esc to close.
- Settings: history limit from 10 to 1000 entries with confirmation before removing old ones, clear history (also deletes it from disk).
- Settings → Storage: how much the history takes, split into text and passwords, and how much memory the app uses. An optional size limit (100 MB, 500 MB, 1 GB; no limit by default) asks before removing old items and says how much space that frees. Clear History says how many items and how much space it removes.
- Pauses while the Mac sleeps or the screen is locked.
- History window opts out of screen sharing and recordings (some newer capture methods may still show it), and closes when the Mac sleeps, the screen locks or another user switches in.
- Passwords are not kept by default: items marked as concealed, and anything copied while a known password manager is in front, are skipped. Items marked as transient or auto-generated are always skipped.
- A password copied without a marker leaves the history when its password manager clears the clipboard within 3 minutes of the copy.
- Settings → Passwords → Save passwords (off by default): passwords are kept hidden in the history, can be revealed one at a time with an eye button, are left out of search and are removed after 1 minute, 10 minutes or 1 hour. Turning it off removes them at once. A password copied back from the history is marked as concealed, so other clipboard managers skip it.
- Passwords saved on disk are encrypted with AES-256-GCM. The key is created on this Mac and kept in your Keychain, never synced to iCloud; if it cannot be read, passwords are kept in memory only.
- English and Russian localization.
- Requires macOS 15 Sequoia or later.
- No menu bar or Dock icon. Sandboxed, no network access.
- Settings open on first launch and explain how to open the history, with a button to quit the app.
