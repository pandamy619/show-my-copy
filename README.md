<h1 align="center">Show My Copy</h1>

<p align="center">Clipboard history for macOS, one hotkey away.</p>

<p align="center">
  <img src="https://img.shields.io/badge/status-in%20development-orange" alt="In development">
  <img src="https://img.shields.io/badge/macOS-14%2B-black" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License">
</p>

<p align="center"><a href="README.ru.md">Русская версия</a></p>

## Planned features

- **Background history.** Everything you copy is collected quietly: text, rich text, images and files.
- **Hotkey window.** A customizable shortcut (⌘⇧V by default) opens your recent copies on top of any app. Search, arrow keys, Enter to copy.
- **Control Center button** on macOS 26.
- **Passwords stay hidden.** Entries from password managers are masked until you reveal them, encrypted on disk and deleted after a set time.
- **You choose the limits.** Set how many entries to keep and see how much disk and memory the history uses.
- **No menu bar icon, no Dock icon.**
- **Private by design.** History stays on your Mac. No analytics, no network.

See [SECURITY.md](SECURITY.md) for the security model.

## Building

Requires Xcode 26.

```sh
make lint   # SwiftLint + swift-format
make test   # unit tests
```

Open `ShowMyCopy.xcodeproj` and run the `ShowMyCopy` scheme.

## License

[MIT](LICENSE)
