import Testing

@testable import ShowMyCopy

/// Which key is pressed for ⌘V, from what each key types with ⌘ on the layout macOS uses for ⌘ shortcuts.
struct PasteKeyTests {
    /// The letter keys of US QWERTY, by virtual key code (Carbon's `kVK_ANSI_*`).
    private static let qwerty: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b", 12: "q", 13: "w",
        14: "e", 15: "r", 16: "y", 17: "t", 31: "o", 32: "u", 34: "i", 35: "p", 37: "l", 38: "j", 40: "k", 45: "n",
        46: "m",
    ]

    /// Dvorak moves V to the key QWERTY has "." on, and puts "k" where QWERTY has V.
    private static let dvorak: [UInt16: String] = [
        0: "a", 1: "o", 2: "e", 3: "u", 4: "d", 5: "i", 6: ";", 7: "q", 8: "j", 9: "k", 11: "x", 12: "'", 13: ",",
        14: ".", 15: "p", 16: "f", 17: "y", 31: "r", 32: "g", 34: "c", 35: "l", 37: "n", 38: "h", 40: "t", 45: "b",
        46: "m", 47: "v",
    ]

    @Test func usesTheAnsiKeyOnQwerty() {
        #expect(PasteKey.keyCode { Self.qwerty[$0] } == PasteKey.ansiV)
        #expect(PasteKey.ansiV == 9)
    }

    @Test func findsVWhereALatinLayoutMovesIt() {
        #expect(PasteKey.keyCode { Self.dvorak[$0] } == 47)
    }

    /// "Dvorak – QWERTY ⌘" types Dvorak, but QWERTY while ⌘ is held. The lookup is made with ⌘ held, so it sees
    /// QWERTY and presses the ANSI key, as the user does.
    @Test func usesTheAnsiKeyOnALayoutThatSwitchesToQwertyWithCommand() {
        let dvorakQwertyCommand = Self.qwerty
        #expect(PasteKey.keyCode { dvorakQwertyCommand[$0] } == PasteKey.ansiV)
    }

    @Test func capitalVCounts() {
        #expect(PasteKey.keyCode { $0 == 47 ? "V" : nil } == 47)
    }

    /// Without a readable layout, or one that types no V with ⌘ (a non-Latin layout read by mistake), the ANSI key
    /// is right for every layout whose ⌘ shortcuts come from QWERTY, Russian among them.
    @Test(arguments: [
        [UInt16: String](),
        [9: "м", 8: "с", 0: "ф"],
    ])
    func fallsBackToTheAnsiKey(layout: [UInt16: String]) {
        #expect(PasteKey.keyCode { layout[$0] } == PasteKey.ansiV)
    }

    @Test func prefersTheAnsiKeyWhenVIsOnTwoKeys() {
        let layout: [UInt16: String] = [3: "v", 9: "v"]
        #expect(PasteKey.keyCode { layout[$0] } == PasteKey.ansiV)
    }

    @Test func asksOnlyAboutVirtualKeyCodes() {
        var asked: [UInt16] = []
        _ = PasteKey.keyCode { keyCode in
            asked.append(keyCode)
            return nil
        }
        #expect(asked.allSatisfy { $0 < 128 })
        #expect(Set(asked).count == 128)
    }
}
