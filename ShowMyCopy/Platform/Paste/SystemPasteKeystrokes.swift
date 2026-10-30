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

    /// Posts ⌘V down and up to the session, where the window server sends it to the active app's key window.
    ///
    /// The key is the one the user would press for ⌘V (`PasteKey`), and the events carry "v" as their text, as a real
    /// ⌘V does on every layout, so apps that match the text and apps that match the key both see ⌘V. The events have
    /// only ⌘ set, so a modifier the user still holds, such as ⌥ after ⌥Return, does not change the shortcut. Real key
    /// presses are held back for a moment while the paste is posted, so typing does not mix into it.
    func postPaste() -> Bool {
        let keyCode = Self.pasteKeyCode()
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            return false
        }
        let text = Array(PasteKey.letter.utf16)
        for event in [down, up] {
            event.flags = Self.commandFlags
            event.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text)
        }
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
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
