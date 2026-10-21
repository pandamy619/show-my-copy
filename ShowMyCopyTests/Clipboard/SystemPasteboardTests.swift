import AppKit
import Testing

@testable import ShowMyCopy

/// Stands in for `NSPasteboard`, so the tests can see what `SystemPasteboard` writes.
@MainActor
final class FakePasteboardBackend: PasteboardBackend {
    var changeCount = 0
    var types: [NSPasteboard.PasteboardType]? = []
    private(set) var strings: [NSPasteboard.PasteboardType: String] = [:]
    private(set) var preparedOptions: [NSPasteboard.ContentsOptions] = []
    /// Types whose `setString` fails.
    var failingTypes: Set<NSPasteboard.PasteboardType> = []
    /// Runs once after the next `prepareForNewContents`, to simulate another app writing right after it.
    var afterPrepare: (@MainActor (FakePasteboardBackend) -> Void)?
    /// Runs once after the next successful `setString`, to simulate another app writing right after it.
    var afterSetString: (@MainActor (FakePasteboardBackend) -> Void)?
    /// Like `NSPasteboard`, only the app that prepared the current contents can add to them.
    private var ownedChangeCount: Int?

    func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int {
        preparedOptions.append(options)
        changeCount += 1
        strings = [:]
        types = []
        let count = changeCount
        ownedChangeCount = count
        if let hook = afterPrepare {
            afterPrepare = nil
            hook(self)
        }
        return count
    }

    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        guard !failingTypes.contains(dataType), ownedChangeCount == changeCount else {
            return false
        }
        strings[dataType] = string
        types = (types ?? []) + [dataType]
        if let hook = afterSetString {
            afterSetString = nil
            hook(self)
        }
        return true
    }

    func string(forType dataType: NSPasteboard.PasteboardType) -> String? {
        strings[dataType]
    }

    /// Another app takes over the pasteboard.
    func otherAppCopies(_ text: String) {
        changeCount += 1
        strings = [.string: text]
        types = [.string]
    }
}

@MainActor
struct SystemPasteboardTests {
    private let backend = FakePasteboardBackend()
    private let sourceType = NSPasteboard.PasteboardType(PasteboardMarker.source)
    private let concealedType = NSPasteboard.PasteboardType(PasteboardMarker.concealed)

    @Test func writeReturnsTheChangeCountOfItsOwnItem() throws {
        backend.changeCount = 41
        let pasteboard = SystemPasteboard(pasteboard: backend, bundleIdentifier: "com.example.ShowMyCopy")

        let changeCount = try #require(pasteboard.write("hello"))
        #expect(changeCount == 42)
        #expect(backend.changeCount == 42)
        #expect(pasteboard.string() == "hello")
    }

    @Test func writeStaysOnThisMacAndNamesTheApp() {
        let pasteboard = SystemPasteboard(pasteboard: backend, bundleIdentifier: "com.example.ShowMyCopy")
        pasteboard.write("hello")

        #expect(backend.preparedOptions == [.currentHostOnly])
        #expect(backend.string(forType: sourceType) == "com.example.ShowMyCopy")
        #expect(pasteboard.types.contains(sourceType))
    }

    @Test func writeWithoutBundleIdentifierAddsNoSourceMarker() {
        let pasteboard = SystemPasteboard(pasteboard: backend, bundleIdentifier: nil)
        pasteboard.write("hello")
        #expect(!pasteboard.types.contains(sourceType))
        #expect(pasteboard.string() == "hello")
    }

    @Test func writeFailsWhenTheTextCannotBeSet() {
        backend.failingTypes = [.string]
        let pasteboard = SystemPasteboard(pasteboard: backend, bundleIdentifier: "com.example.ShowMyCopy")
        #expect(pasteboard.write("hello") == nil)
    }

    @Test func writeFailsWhenAnotherAppWritesBeforeTheText() {
        backend.afterPrepare = { $0.otherAppCopies("from another app") }
        let pasteboard = SystemPasteboard(pasteboard: backend, bundleIdentifier: "com.example.ShowMyCopy")
        #expect(pasteboard.write("hello") == nil)
        #expect(pasteboard.string() == "from another app")
    }

    @Test func writeFailsWhenAnotherAppWritesRightAfterTheText() {
        backend.afterSetString = { $0.otherAppCopies("from another app") }
        let pasteboard = SystemPasteboard(pasteboard: backend, bundleIdentifier: "com.example.ShowMyCopy")
        // Returning the newer count would make the monitor ignore the other app's copy.
        #expect(pasteboard.write("hello") == nil)
        #expect(pasteboard.string() == "from another app")
    }

    @Test func plainWriteHasNoConcealedMarker() {
        let pasteboard = SystemPasteboard(pasteboard: backend, bundleIdentifier: "com.example.ShowMyCopy")
        pasteboard.write("hello")
        #expect(!pasteboard.types.contains(concealedType))
    }

    @Test func concealedWriteIsMarkedAndStaysOnThisMac() throws {
        backend.changeCount = 7
        let pasteboard = SystemPasteboard(pasteboard: backend, bundleIdentifier: "com.example.ShowMyCopy")

        let changeCount = try #require(pasteboard.write("hunter2", concealed: true))
        #expect(changeCount == 8)
        #expect(backend.preparedOptions == [.currentHostOnly])
        #expect(pasteboard.string() == "hunter2")
        #expect(backend.string(forType: sourceType) == "com.example.ShowMyCopy")
        // Other clipboard managers check the marker as soon as the text appears, so it goes first.
        #expect(pasteboard.types.first == concealedType)
    }

    @Test func concealedWriteFailsWithoutTheMarker() {
        backend.failingTypes = [concealedType]
        let pasteboard = SystemPasteboard(pasteboard: backend, bundleIdentifier: "com.example.ShowMyCopy")
        // Without the marker other clipboard managers would keep the password, so the text is not written.
        #expect(pasteboard.write("hunter2", concealed: true) == nil)
        #expect(pasteboard.string() == nil)
    }

    @Test func readsPassThrough() {
        backend.otherAppCopies("copied")
        backend.types = nil
        let pasteboard = SystemPasteboard(pasteboard: backend, bundleIdentifier: nil)
        #expect(pasteboard.changeCount == 1)
        #expect(pasteboard.types.isEmpty)
        #expect(pasteboard.string() == "copied")
    }
}
