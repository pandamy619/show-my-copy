/// One key event of the ⌘V the app posts. `SystemPasteKeystrokes` turns each into a Core Graphics event.
struct PasteKeyEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A modifier key went down or up (`kCGEventFlagsChanged`).
        case flagsChanged
        case keyDown
        case keyUp
    }

    let kind: Kind
    /// A virtual key code (`PasteKey`).
    let keyCode: UInt16
    /// Whether the event has ⌘ set, and no other modifier. Otherwise it has none.
    let holdsCommand: Bool
    /// The text the event carries, or nil to leave it to macOS.
    let text: String?
}

/// Where in the window server the events enter. All three need only the `PostEvent` privilege, which works in the
/// App Sandbox.
enum PasteEventTap: Equatable, Sendable {
    /// Where events from the keyboard enter the login session (`kCGSessionEventTap`), as Maccy posts ⌘V.
    case session
    /// After the window server chose the app the event goes to (`kCGAnnotatedSessionEventTap`), as Clipy posts ⌘V.
    case annotatedSession
    /// Where events from the keyboard hardware enter the window server (`kCGHIDEventTap`).
    case hid
}

/// How the app posts ⌘V: which events, with what, where.
///
/// A real ⌘V is four events: ⌘ goes down (a flags-changed event), V goes down and up with ⌘ set, ⌘ goes up. The app
/// posts all four by default: some apps follow the ⌘ key's own events (Chromium forwards them to the page as a Meta
/// key press), and posting the ⌘ key also sets ⌘ in the session's modifier state while V is handled. Maccy and Clipy
/// post only V down and up with ⌘ set.
///
/// The V events carry "v" as their text by default, as a real ⌘V does on every layout (macOS takes ⌘ shortcuts from
/// the ASCII-capable layout, so with Russian it is "v", not "м"). Without it macOS would fill in the text from the
/// current layout. The key code is the one `PasteKey` found, so apps that match the key and apps that match the text
/// both see ⌘V.
struct PastePostingStyle: Equatable, Sendable {
    /// Whether ⌘ goes down before V and up after it, as separate events.
    var pressesCommandKey: Bool
    /// Whether the V events carry "v" as their text.
    var carriesText: Bool
    var tap: PasteEventTap

    static let standard = PastePostingStyle(pressesCommandKey: true, carriesText: true, tap: .session)

    /// The events for ⌘V with V on `pasteKeyCode`, in the order they are posted. Every event that holds ⌘ is
    /// followed by one that lets it go, so ⌘ is never left down.
    func events(pasteKeyCode: UInt16) -> [PasteKeyEvent] {
        let text = carriesText ? PasteKey.letter : nil
        let paste = [
            PasteKeyEvent(kind: .keyDown, keyCode: pasteKeyCode, holdsCommand: true, text: text),
            PasteKeyEvent(kind: .keyUp, keyCode: pasteKeyCode, holdsCommand: true, text: text),
        ]
        guard pressesCommandKey else {
            return paste
        }
        let commandDown = PasteKeyEvent(
            kind: .flagsChanged, keyCode: PasteKey.leftCommand, holdsCommand: true, text: nil)
        let commandUp = PasteKeyEvent(
            kind: .flagsChanged, keyCode: PasteKey.leftCommand, holdsCommand: false, text: nil)
        return [commandDown] + paste + [commandUp]
    }
}

/// What the paster uses for one paste: how long it waits and how it posts ⌘V.
struct PasteTuning: Equatable, Sendable {
    var timing: PasteTiming
    var style: PastePostingStyle

    static let standard = PasteTuning(timing: .standard, style: .standard)
}
