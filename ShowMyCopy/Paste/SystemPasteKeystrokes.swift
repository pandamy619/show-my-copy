import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Posts ⌘V with Core Graphics, and asks macOS whether the app may.
///
/// Posting key events needs the `PostEvent` privilege, which System Settings list under Privacy & Security →
/// Accessibility. It works in the App Sandbox and needs no entitlement. The app checks and requests it with
/// `CGPreflightPostEventAccess` and `CGRequestPostEventAccess` (macOS 10.15 and later), not with
/// `AXIsProcessTrustedWithOptions`, which is about the full Accessibility privilege that the sandbox does not allow
/// and the app does not use. Nothing here reads key events: no event tap, no event monitor, no Input Monitoring.
@MainActor
final class SystemPasteKeystrokes: PasteAccessChecking, PasteKeystrokePosting {
    /// ⌘ as a device-independent flag, plus the bit for the left ⌘ key (`NX_DEVICELCMDKEYMASK`), as a real key press
    /// sets it: some apps look at the device bits.
    private static let commandFlags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x0000_0008)

    func isGranted() -> Bool {
        CGPreflightPostEventAccess()
    }

    @discardableResult
    func request() -> Bool {
        CGRequestPostEventAccess()
    }

    /// Posts ⌘V as `style` says (`PastePostingStyle.events(pasteKeyCode:)`), by default ⌘ down, V down and up, ⌘ up,
    /// to the session, where the window server sends it to the active app's key window.
    ///
    /// The V key is the one the user would press for ⌘V (`PasteKey`). The events have only ⌘ set, so a modifier the
    /// user still holds, such as ⌥ after ⌥Return, does not change the shortcut. Real key presses are held back for a
    /// moment while the paste is posted, so typing does not mix into it. All events are made before the first is
    /// posted, so ⌘ never goes down without going up again.
    func postPaste(_ style: PastePostingStyle) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        var events: [CGEvent] = []
        for key in style.events(pasteKeyCode: UInt16(Self.pasteKeyCode())) {
            guard let event = Self.makeEvent(key, source: source) else {
                return false
            }
            events.append(event)
        }
        let tap = Self.location(of: style.tap)
        for event in events {
            event.post(tap: tap)
        }
        return true
    }

    private static func makeEvent(_ key: PasteKeyEvent, source: CGEventSource) -> CGEvent? {
        let keyDown = key.kind != .keyUp
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key.keyCode), keyDown: keyDown)
        else {
            return nil
        }
        if key.kind == .flagsChanged {
            event.type = .flagsChanged
        }
        event.flags = key.holdsCommand ? commandFlags : []
        if let text = key.text {
            let characters = Array(text.utf16)
            event.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters)
        }
        return event
    }

    private static func location(of tap: PasteEventTap) -> CGEventTapLocation {
        switch tap {
        case .session:
            .cgSessionEventTap
        case .annotatedSession:
            .cgAnnotatedSessionEventTap
        case .hid:
            .cghidEventTap
        }
    }

    /// The key the user presses for ⌘V on the layout in use now (`PasteKey`). Read on every paste: the user can
    /// switch layouts at any time.
    static func pasteKeyCode() -> CGKeyCode {
        CGKeyCode(PasteKey.keyCode(letterWithCommand: letterWithCommand()))
    }

    /// What each key types with ⌘ held on the layout macOS uses for ⌘ shortcuts: the current layout when it types
    /// Latin letters, otherwise the user's last ASCII-capable one (for example ABC with a Russian layout). Returns a
    /// lookup that always answers nil when no layout can be read; `PasteKey` then uses the ANSI V key.
    ///
    /// Text Input Sources must be read on the main thread.
    private static func letterWithCommand() -> (UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
            let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return { _ in nil }
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())
        let commandState = UInt32((cmdKey >> 8) & 0xFF)
        return { keyCode in
            layoutData.withUnsafeBytes { bytes -> String? in
                guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                    return nil
                }
                var deadKeyState: UInt32 = 0
                var characters = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout,
                    keyCode,
                    UInt16(kUCKeyActionDown),
                    commandState,
                    keyboardType,
                    OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    characters.count,
                    &length,
                    &characters
                )
                guard status == OSStatus(noErr), length > 0 else {
                    return nil
                }
                return String(utf16CodeUnits: characters, count: length)
            }
        }
    }
}
