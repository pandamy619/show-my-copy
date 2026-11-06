import Carbon.HIToolbox
import Testing

@testable import ShowMyCopy

/// Only what posts nothing: posting ⌘V in a test would paste into whatever app is in front on the Mac running it.
/// Pasting itself is checked by hand (see the paste checks in the pull request).
@MainActor
struct SystemPasteKeystrokesTests {
    @Test func findsTheKeyForCommandVOnTheLayoutInUse() {
        let keyCode = SystemPasteKeystrokes.pasteKeyCode()
        #expect(PasteKey.keyCodes.contains(UInt16(keyCode)))
        // On U.S., ABC and every layout whose ⌘ shortcuts come from them (Russian among them) it is the ANSI V key.
        if ["com.apple.keylayout.US", "com.apple.keylayout.ABC"].contains(Self.commandLayoutID()) {
            #expect(keyCode == CGKeyCode(kVK_ANSI_V))
        }
    }

    /// The layout macOS takes ⌘ shortcuts from now, as `SystemPasteKeystrokes` reads it.
    private static func commandLayoutID() -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() else {
            return nil
        }
        guard let id = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(id).takeUnretainedValue() as String
    }

    @Test func ansiVMatchesCarbon() {
        #expect(PasteKey.ansiV == UInt16(kVK_ANSI_V))
    }

    @Test func leftCommandMatchesCarbon() {
        #expect(PasteKey.leftCommand == UInt16(kVK_Command))
    }

    /// Asking whether the app may post events shows nothing and changes nothing, so it gives the same answer twice.
    /// The test never calls `request()`, which can show macOS's alert.
    @Test func checkingThePermissionShowsNothing() {
        let keystrokes = SystemPasteKeystrokes()
        #expect(keystrokes.isGranted() == keystrokes.isGranted())
    }
}
