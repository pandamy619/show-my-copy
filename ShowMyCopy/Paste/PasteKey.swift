/// Which physical key the app presses for ⌘V.
///
/// Key events carry a virtual key code: a position on the keyboard, named after the US ANSI layout, not a letter.
/// Apps match ⌘ shortcuts by the letter the layout gives that key with ⌘. So the app presses the key the user would
/// press for ⌘V on their keyboard:
///
/// - On layouts that do not type Latin letters, such as Russian, macOS takes ⌘ shortcuts from the user's
///   ASCII-capable layout (for example ABC or U.S.). There the V key is the ANSI one, so the app sends that
///   (`kVK_ANSI_V`, 9), the key labelled V and М on a Russian keyboard.
/// - On Latin layouts that move V, such as Dvorak, V is elsewhere (47 on Dvorak), and the ANSI position would be
///   another letter. The app looks it up.
/// - Layouts such as "Dvorak – QWERTY ⌘" switch to QWERTY while ⌘ is held. The lookup is made with ⌘ held, so it
///   finds the ANSI position there.
///
/// The live code asks the system's current ASCII-capable layout for each key's letter with ⌘ held
/// (`SystemPasteKeystrokes`); this type only decides from those answers, so it is tested without macOS.
enum PasteKey {
    /// `kVK_ANSI_V` from Carbon's `Events.h`: the V key on a US keyboard.
    static let ansiV: UInt16 = 9

    /// `kVK_Command` from Carbon's `Events.h`: the left ⌘ key, the same on every layout.
    static let leftCommand: UInt16 = 55

    /// Virtual key codes run from 0 to 127.
    static let keyCodes: Range<UInt16> = 0..<128

    /// The letter ⌘V is matched by.
    static let letter = "v"

    /// The key that types `letter` with ⌘ held. `letterWithCommand` gives the text a key types with ⌘ on the layout
    /// macOS uses for ⌘ shortcuts, or nil when it cannot tell. The ANSI key is tried first, so a layout that has V
    /// in two places (rare) uses the usual one. Without an answer (no layout could be read, or no key types V) it is
    /// the ANSI key, which is right for most layouts.
    static func keyCode(letterWithCommand: (UInt16) -> String?) -> UInt16 {
        if types(letterWithCommand(ansiV)) {
            return ansiV
        }
        return keyCodes.first { types(letterWithCommand($0)) } ?? ansiV
    }

    private static func types(_ text: String?) -> Bool {
        text?.lowercased() == letter
    }
}
