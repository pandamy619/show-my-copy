<p align="center">
  <img src="ShowMyCopy/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" alt="Show My Copy">
</p>

<h1 align="center">Show My Copy</h1>

<p align="center">Clipboard history for macOS, one hotkey away.</p>

<p align="center">
  <img src="https://img.shields.io/badge/status-in%20development-orange" alt="In development">
  <img src="https://img.shields.io/badge/macOS-15%2B-black" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License">
</p>

<p align="center"><a href="README.ru.md">Русская версия</a></p>

## Current status (0.1.0)

Show My Copy is in early development. There are no releases yet; build it from source. What works now:

- **Background history of text, rich text, images and files.** What you copy is collected quietly, with the app it came from. Text is kept up to 1 MB per copy, and styled text keeps its formatting when copied back. Images (up to 20 MB each) are kept as files in the app's sandbox with a small thumbnail (images over 120 megapixels without one); copied files are kept as references (path and name), never as copies. An image is listed as soon as you copy it and gets its thumbnail a moment later, and copies made meanwhile are not missed. Copied photos and videos get a small thumbnail when you copy them (a frame for a video). The history window shows thumbnails of images, photos and videos and icons of other files, with a mark on files that may have been moved or deleted.
- **History survives a restart.** It is saved only on your Mac, in the app's sandbox, and left out of backups. Saved passwords are encrypted with a key kept in your Keychain, which is used only if you save passwords.
- **Hotkey window.** ⌥⌘V by default, changeable in Settings, opens your recent copies on top of any app.
- **Control Center button** on macOS 26 and later. Add Clipboard History to Control Center to open the history window with a click; if the app is not running, the button starts it.
- **Search and keyboard navigation.** Type to filter, arrow keys to move, Enter to copy the entry back to the clipboard, Esc to close.
- **Paste into the app you were using, if you want.** Turn on Settings → General → Paste after choosing an entry, and Enter also pastes the entry where you were typing; ⌥Enter only copies. macOS asks you to allow it in Privacy & Security → Accessibility (if you said no, Settings → General has a button that opens that list in System Settings); the app only sends ⌘V after you choose an entry and never reads what you type. Without that permission Enter just copies.
- **Previews.** → (or Show Preview in a row's context menu) shows the selected entry larger: the full image, styled text with its formatting, or the copied files with the folder each one is in and their sizes (no sizes for files on network volumes). The folder is shortened like Finder does it (`~` for your home folder, iCloud Drive by name, cut in the middle when it is long) and can be selected and copied with ⌘C; a path copied this way goes on the clipboard but not into the history. Hover over a file row to see the full paths of its files. ← or Esc closes it. Passwords are never previewed.
- **Delete one entry.** ⌘⌫ (or Delete in a row's context menu, or the VoiceOver action) deletes the selected entry, also the one on the clipboard now; the window stays open and selects the next entry. If the clipboard still holds the deleted entry and nothing was copied since, it is emptied too. ⌘Z brings the entry back while the window is open. A long swipe to the left deletes it at once, as in Mail (see below). Pinned entries and passwords are deleted the same way, and a password is never shown.
- **Swipe for a row's actions.** Swipe a row to the left with two fingers on the trackpad and it shows a button for each action of its context menu, as in Telegram: Show Preview, Pin or Unpin, and Delete in red at the right edge. Click one to do what the menu item does. A long swipe deletes the entry at once. With Reduce Motion the buttons just appear; VoiceOver users have the same actions on the row.
- **Drag into another app.** Drag a row with the mouse into TextEdit, Notes, Mail, a browser field, Finder or a chat, and the app gets the entry as if you pasted it there: text as text, styled text with its formatting, an image as a file in its own format (named like "Image 2026-11-05 at 16.10.png"), copied files as the files themselves. The clipboard and the history stay as they are. The window stays open while you drag and closes after the drop; cancel the drag and it stays open. Passwords cannot be dragged.
- **Pin entries.** ⌘P (or Pin in a row's context menu, or the VoiceOver action) pins the selected entry. Pinned entries stay in their own section under the entry on the clipboard, in the order you pinned them, with a pin mark; new copies never push them down or out. ⌘P again unpins an entry and puts it at the top of the history. Up to 50 entries can be pinned: pinning one more unpins the oldest pinned entry, puts it at the top of the history and says so in the window. Passwords cannot be pinned.
- **Entry limit** from 10 to 1000, 50 by default. Lowering it asks before removing old entries.
- **Old history is removed.** History older than 8 hours is removed by default; configurable in Settings: 1 hour, 8 hours, 24 hours, 7 days, 30 days or off. A shorter limit asks before removing old entries.
- **Pinned entries are kept** by the entry, size and age limits, and by Clear History unless you choose to remove them too. They do not count toward the size limit, so 50 pinned images can take up to about 1 GB more.
- **Clear history** in Settings, with confirmation. It deletes the history from disk too, with any copy of a history that could not be opened.
- **Storage at a glance.** Settings show how much the history takes, split into text, rich text, images, files and passwords, its size on disk, how much memory the app uses, and a warning if the history cannot be saved. A size limit of 100 MB, 500 MB or 1 GB (1 GB by default; it can be turned off) asks before removing old entries.
- **Pauses while the Mac sleeps or the screen is locked.**
- **Passwords are not kept** by default: items that password managers mark as concealed and anything copied from a known password manager are skipped, as are items marked as transient or auto-generated. When a password manager clears a password it copied without a marker, the entry leaves the history too: text copied shortly before the clipboard is emptied, if it stays empty.
- **Excluded apps.** Pick apps in Settings whose copies are never recorded: while one of them is in front, the app does not read the clipboard at all. Add one from the apps that are open now, or any app with Choose an App…; only its bundle identifier and name are kept. The first copy after launch, waking or unlocking has no known app and is recorded.
- **Save passwords, if you want.** Turn it on in Settings to keep passwords hidden in the history: an eye button reveals one, search skips them, and they are removed after 1 minute, 10 minutes or 1 hour. If the clipboard still holds a password when it is removed, the clipboard is emptied too. Settings show their size only rounded up to whole kilobytes, so it never tells a password's length.
- **No menu bar icon, no Dock icon.**
- **Open at login, if you want.** Settings → General → Open at login, off by default; the first launch's Settings offer it once. It is also listed in System Settings → General → Login Items, where you can turn it off.
- **English and Russian** interface.
- **Private by design.** No analytics. Sandboxed without network access, so the app itself makes no connections; the only file access it asks for is reading the app you choose in Settings → Excluded apps; file thumbnails are drawn by macOS QuickLook outside the sandbox, for local files only (see [SECURITY.md](SECURITY.md)).

The app sends nothing you copy anywhere: see the [privacy policy](PRIVACY.md) for what the app stores, where and for how long, and how to delete all of it.

Deleted entries can stay in the history file's free space until they are overwritten. A password copied without a marker from an app that is not a known password manager, such as a browser extension, can still be kept like normal text — see [SECURITY.md](SECURITY.md) for the details and known limitations.

## Building

Requires Xcode 26 and macOS 15+.

Open `ShowMyCopy.xcodeproj` and run the `ShowMyCopy` scheme.

Settings every target shares (Swift 6 with complete concurrency checking, warnings as errors, the deployment target, the sandbox and no network access) are in `Config/Shared.xcconfig`; `make lint` checks the sandbox and network settings every target ends up with.

| Command | Description |
|---|---|
| `make test` | unit tests (Swift Testing) |
| `make lint` | SwiftLint + swift-format, strict; security and translation checks |
| `make format` | auto-format |
| `make security` | build Release with ad-hoc signing and check its entitlements and that it has no Debug-only code |
| `make security-selftest` | check that every security check can fail (runs on Linux too) |

`make lint` needs SwiftLint: `brew install swiftlint`.

Only one copy of the app runs at a time. A Debug build run from Xcode replaces a Debug build that is already running; next to a Release copy, such as the installed app at login, it quits after a few seconds and the installed app shows its Settings. Quit that copy first: `pkill -x ShowMyCopy`.

`make lint` also checks the app's privacy manifest against the code (`scripts/check_privacy_manifest.py`) and the App Store texts in `AppStore/metadata` against App Store Connect's length limits (`scripts/check_store_metadata.py`).

## Mac App Store

The app is being prepared for the Mac App Store: [checklist](AppStore/CHECKLIST.md), [store texts](AppStore/metadata), [notes for App Review](AppStore/review-notes.md) and the [privacy policy](PRIVACY.md).

## License

[MIT](LICENSE)
