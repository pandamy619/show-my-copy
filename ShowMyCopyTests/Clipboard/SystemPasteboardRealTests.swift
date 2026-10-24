import AppKit
import Testing

@testable import ShowMyCopy

/// Runs `SystemPasteboard` and the snapshot reader against real `NSPasteboard`s, to check what the fakes assume.
///
/// Each test uses its own named pasteboard, so the tests never touch the user's clipboard and can run in parallel.
/// macOS only: the Linux stub build leaves this file out, because its `NSPasteboard` stand-in holds no data.
@MainActor
struct SystemPasteboardRealTests {
    private let bundleIdentifier = "com.example.ShowMyCopy"
    private let concealedType = NSPasteboard.PasteboardType(PasteboardMarker.concealed)
    private let sourceType = NSPasteboard.PasteboardType(PasteboardMarker.source)

    /// Runs `body` with a new, empty pasteboard of its own and releases the pasteboard afterwards.
    private func withIsolatedPasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ShowMyCopyTests-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        _ = pasteboard.clearContents()
        try body(pasteboard)
    }

    private func read(_ pasteboard: NSPasteboard, savesPasswords: Bool = false) -> CapturedItem {
        PasteboardSnapshotReader(pasteboard: SystemPasteboard(pasteboard: pasteboard, bundleIdentifier: nil))
            .read(fromPasswordManager: false, savesPasswords: savesPasswords)
    }

    @Test func writtenTextReadsBackAsStringAndUTF8Data() throws {
        try withIsolatedPasteboard { backend in
            let pasteboard = SystemPasteboard(pasteboard: backend, bundleIdentifier: bundleIdentifier)
            let changeCount = try #require(pasteboard.write("Café ☕️"))

            #expect(changeCount == backend.changeCount)
            #expect(pasteboard.string() == "Café ☕️")
            #expect(pasteboard.data(forType: .string) == Data("Café ☕️".utf8))
            #expect(read(backend) == .content(.text("Café ☕️"), isSecret: false))
        }
    }

    @Test func textWrittenByAnotherAppIsReadThroughItsData() {
        withIsolatedPasteboard { backend in
            // How most apps copy text: as a string object, not as data of a chosen type.
            #expect(backend.writeObjects(["from another app" as NSString]))
            let pasteboard = SystemPasteboard(pasteboard: backend, bundleIdentifier: nil)

            #expect(pasteboard.data(forType: .string) == Data("from another app".utf8))
            #expect(read(backend) == .content(.text("from another app"), isSecret: false))
        }
    }

    @Test func concealedWriteIsSkippedOrKeptAsASecret() throws {
        try withIsolatedPasteboard { backend in
            let pasteboard = SystemPasteboard(pasteboard: backend, bundleIdentifier: bundleIdentifier)
            _ = try #require(pasteboard.write("hunter2", concealed: true))

            #expect(pasteboard.types.contains(concealedType))
            #expect(read(backend) == .skipped(.secret))
            #expect(read(backend, savesPasswords: true) == .content(.text("hunter2"), isSecret: true))
        }
    }

    @Test func sourceMarkerNamesTheAppAndIsNotContent() throws {
        try withIsolatedPasteboard { backend in
            let pasteboard = SystemPasteboard(pasteboard: backend, bundleIdentifier: bundleIdentifier)
            _ = try #require(pasteboard.write("hello"))

            #expect(pasteboard.types.contains(sourceType))
            #expect(backend.string(forType: sourceType) == bundleIdentifier)
            #expect(read(backend) == .content(.text("hello"), isSecret: false))
        }
    }

    @Test func currentHostOnlyWriteCanBeReadThroughAnotherReference() throws {
        try withIsolatedPasteboard { backend in
            let writer = SystemPasteboard(pasteboard: backend, bundleIdentifier: bundleIdentifier)
            let changeCount = try #require(writer.write("only on this Mac"))

            // `.currentHostOnly` keeps the item off other devices, not away from other readers on this Mac.
            let sameName = NSPasteboard(name: backend.name)
            let reader = SystemPasteboard(pasteboard: sameName, bundleIdentifier: nil)
            #expect(reader.changeCount == changeCount)
            #expect(reader.string() == "only on this Mac")
            #expect(reader.data(forType: .string) == Data("only on this Mac".utf8))
        }
    }

    @Test func textOverTheLimitIsSkippedByItsDataSize() {
        withIsolatedPasteboard { backend in
            let tooLarge = String(repeating: "a", count: ClipboardMonitor.maximumTextBytes + 1)
            #expect(backend.setString(tooLarge, forType: .string))

            let pasteboard = SystemPasteboard(pasteboard: backend, bundleIdentifier: nil)
            #expect(pasteboard.data(forType: .string)?.count == ClipboardMonitor.maximumTextBytes + 1)
            #expect(read(backend) == .skipped(.tooLarge))
        }
    }

    @Test func textOfExactlyTheLimitIsRead() {
        withIsolatedPasteboard { backend in
            let text = String(repeating: "a", count: ClipboardMonitor.maximumTextBytes)
            #expect(backend.setString(text, forType: .string))
            #expect(read(backend) == .content(.text(text), isSecret: false))
        }
    }

    @Test func emptiedPasteboardIsCleared() {
        withIsolatedPasteboard { backend in
            #expect(read(backend) == .cleared)
        }
    }

    @Test func monitorRecordsACopyFromARealPasteboard() {
        withIsolatedPasteboard { backend in
            let history = ClipboardHistory()
            let monitor = MonitorFactory.make(
                pasteboard: SystemPasteboard(pasteboard: backend, bundleIdentifier: nil), history: history)
            monitor.poll()
            // Another app takes the pasteboard over, which gives it a new change count.
            _ = backend.clearContents()
            #expect(backend.writeObjects(["copied" as NSString]))
            monitor.poll()
            #expect(history.entries.map(\.text) == ["copied"])
        }
    }
}
