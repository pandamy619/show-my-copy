<p align="center">
  <img src="ShowMyCopy/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" alt="Show My Copy">
</p>

<h1 align="center">Show My Copy</h1>

<p align="center">Clipboard history for macOS, one hotkey away.</p>

<p align="center">
  <img src="https://img.shields.io/badge/status-in%20development-orange" alt="In development">
  <img src="https://img.shields.io/badge/macOS-14%2B-black" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License">
</p>

<p align="center"><a href="README.ru.md">Русская версия</a></p>

## Current status (0.1)

Show My Copy is in early development. There are no releases yet; build it from source. What works now:

- **Background history of text.** Text you copy is collected quietly, with the app it came from.
- **Hotkey window.** ⌘⇧V by default, changeable in Settings, opens your recent copies on top of any app.
- **Search and keyboard navigation.** Type to filter, arrow keys to move, Enter to copy the entry back to the clipboard, Esc to close.
- **Entry limit** from 10 to 1000, 50 by default. Lowering it asks before removing old entries.
- **Clear history** in Settings, with confirmation.
- **Pauses while the Mac sleeps or the screen is locked.**
- **Skips passwords** that password managers mark as concealed, and other items marked as transient or auto-generated.
- **No menu bar icon, no Dock icon.**
- **English and Russian** interface.
- **Private by design.** No analytics, no network, sandboxed.

History is kept in memory only and is lost when you quit the app. Passwords copied without a marker are kept like normal text for now — see [SECURITY.md](SECURITY.md) for the details and known limitations.

## Planned features

Not available yet:

- **More than text.** Rich text, images and files.
- **History that survives a restart,** stored only on your Mac.
- **Control Center button** on macOS 26.
- **Passwords stay hidden.** Entries from password managers are masked until you reveal them, encrypted on disk and deleted after a set time.
- **Usage at a glance.** See how much disk and memory the history uses.

## Building

Requires Xcode 26 and macOS 14+.

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
