# Changelog

## [Unreleased]

First version, 0.1.0. Not released yet.

- Clipboard history of text in the background, with the app it was copied from. History is kept in memory only.
- History window on a global shortcut (⌥⌘V by default, changeable in Settings), on top of any app.
- Search, arrow keys to select, Enter to copy an entry back, Esc to close.
- Settings: history limit from 10 to 1000 entries with confirmation before removing old ones, clear history.
- Pauses while the Mac sleeps or the screen is locked.
- History window opts out of screen sharing and recordings (some newer capture methods may still show it), and closes when the Mac sleeps, the screen locks or another user switches in.
- Passwords are not kept by default: items marked as concealed, and anything copied while a known password manager is in front, are skipped. Items marked as transient or auto-generated are always skipped.
- A password copied without a marker leaves the history when its password manager clears the clipboard within 3 minutes of the copy.
- Settings → Passwords → Save passwords (off by default): passwords are kept hidden in the history, can be revealed one at a time with an eye button, are left out of search and are removed after 1 minute, 10 minutes or 1 hour. Turning it off removes them at once. A password copied back from the history is marked as concealed, so other clipboard managers skip it.
- English and Russian localization.
- No menu bar or Dock icon. Sandboxed, no network access.
- Settings open on first launch and explain how to open the history, with a button to quit the app.
