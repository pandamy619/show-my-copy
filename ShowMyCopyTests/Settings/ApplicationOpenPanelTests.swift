import Foundation
import Testing

@testable import ShowMyCopy

/// What Choose an App… reads from the bundle picked in the open panel. The panel itself needs a person; these read
/// bundles directly, as the panel's code does after the user picks one.
struct ApplicationOpenPanelTests {
    private func withFolder(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "ApplicationOpenPanelTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: folder)
            } catch {
                Issue.record("Could not remove the test folder: \(error)")
            }
        }
        try body(folder)
    }

    private func bundle(in folder: URL, named name: String, infoPlist: Data?) throws -> URL {
        let bundle = folder.appending(path: name, directoryHint: .isDirectory)
        let contents = bundle.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        if let infoPlist {
            try infoPlist.write(to: contents.appending(path: "Info.plist"))
        }
        return bundle
    }

    @Test func textEditHasItsBundleIdentifierAndName() {
        let chosen = ApplicationOpenPanel.read(bundleAt: URL(filePath: "/System/Applications/TextEdit.app"))

        #expect(chosen.bundleIdentifier == "com.apple.TextEdit")
        #expect(chosen.name == "TextEdit")
    }

    @Test func bundleWithoutAnInfoPlistHasNoBundleIdentifier() throws {
        try withFolder { folder in
            let chosen = ApplicationOpenPanel.read(
                bundleAt: try bundle(in: folder, named: "Empty.app", infoPlist: nil))

            #expect(chosen == ChosenApp(bundleIdentifier: nil, name: "Empty"))
        }
    }

    @Test func infoPlistOverTheLimitIsNotParsed() throws {
        try withFolder { folder in
            let padding = String(repeating: "x", count: ChosenApp.maximumInfoPlistBytes)
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleIdentifier": "com.example.large", "Padding": padding], format: .xml,
                options: 0)

            let chosen = ApplicationOpenPanel.read(
                bundleAt: try bundle(in: folder, named: "Large.app", infoPlist: data))

            #expect(chosen.bundleIdentifier == nil)
        }
    }

    @Test func ownBundleIsReadLikeAnyOther() throws {
        // The decision to skip this app is made from its identifier (`ExcludedApps.add(chosen:)`), not its path.
        let own = ApplicationOpenPanel.read(bundleAt: Bundle.main.bundleURL)
        #expect(own.bundleIdentifier == Bundle.main.bundleIdentifier)
    }
}
