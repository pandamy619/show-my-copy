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

## Current status (0.1)

Show My Copy is in early development. There are no releases yet; build it from source. What works now:

- **Background history of text.** Text you copy is collected quietly, with the app it came from.
- **History survives a restart.** It is saved only on your Mac, in the app's sandbox, and left out of backups. Saved passwords are encrypted with a key kept in your Keychain.
- **Hotkey window.** ⌥⌘V by default, changeable in Settings, opens your recent copies on top of any app.
- **Search and keyboard navigation.** Type to filter, arrow keys to move, Enter to copy the entry back to the clipboard, Esc to close.
- **Entry limit** from 10 to 1000, 50 by default. Lowering it asks before removing old entries.
- **Clear history** in Settings, with confirmation. It deletes the history from disk too.
- **Storage at a glance.** Settings show how much the history takes, split into text and passwords, and how much memory the app uses. An optional size limit of 100 MB, 500 MB or 1 GB asks before removing old entries.
- **Pauses while the Mac sleeps or the screen is locked.**
- **Passwords are not kept** by default: items that password managers mark as concealed and anything copied from a known password manager are skipped, as are items marked as transient or auto-generated. When a password manager clears a password it copied without a marker, the entry leaves the history too.
- **Save passwords, if you want.** Turn it on in Settings to keep passwords hidden in the history: an eye button reveals one, search skips them, and they are removed after 1 minute, 10 minutes or 1 hour.
- **No menu bar icon, no Dock icon.**
- **English and Russian** interface.
- **Private by design.** No analytics, no network, sandboxed.

Deleted entries can stay in the history file's free space until they are overwritten. A password copied without a marker from an app that is not a known password manager, such as a browser extension, can still be kept like normal text — see [SECURITY.md](SECURITY.md) for the details and known limitations.

## Planned features

Not available yet:

- **More than text.** Rich text, images and files.
- **Control Center button** on macOS 26.
- **Disk usage of the saved history** in Settings.

## Building

Requires Xcode 26 and macOS 15+.

Open `ShowMyCopy.xcodeproj` and run the `ShowMyCopy` scheme.

| Command | Description |
|---|---|
| `make test` | unit tests (Swift Testing) |
| `make lint` | SwiftLint + swift-format, strict; security and translation checks |
| `make format` | auto-format |
| `make security` | build Release with ad-hoc signing and check its entitlements |

`make lint` needs SwiftLint: `brew install swiftlint`.

## License

[MIT](LICENSE)
