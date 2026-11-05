import Foundation
import Testing

@testable import ShowMyCopy

/// Settings → Excluded apps → Choose an App…: what is read from the picked bundle, and which picks are added.
@MainActor
struct ChosenAppTests {
    private let running = FakeRunningApps()
    private let chooser = FakeAppChooser()
    private static let ownBundleIdentifier = "com.pandamy619.ShowMyCopy"
    private let textEdit = ChosenApp(bundleIdentifier: "com.apple.TextEdit", name: "TextEdit")

    private func make(_ defaults: UserDefaults) -> ExcludedApps {
        ExcludedApps(
            defaults: defaults, running: running, chooser: chooser, ownBundleIdentifier: Self.ownBundleIdentifier)
    }

    private func withApps(_ body: @MainActor (ExcludedApps, UserDefaults) async throws -> Void) async throws {
        try await ContainerFactory.withDefaults { defaults in
            try await body(make(defaults), defaults)
        }
    }

    private static func infoPlist(_ info: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
    }

    // MARK: Choosing

    @Test func chosenAppIsAddedAndSurvivesARelaunch() async throws {
        try await withApps { apps, defaults in
            chooser.chosen = textEdit

            let outcome = await apps.chooseApp()

            let added = try #require(ExcludedApp(bundleIdentifier: "com.apple.TextEdit", name: "TextEdit"))
            #expect(outcome == .added(added))
            #expect(apps.excludes(bundleIdentifier: "com.apple.textedit"))
            #expect(make(defaults).apps == [added])
            #expect(chooser.count == 1)
        }
    }

    @Test func cancellingChangesNothing() async throws {
        try await withApps { apps, _ in
            chooser.chosen = nil

            #expect(await apps.chooseApp() == nil)
            #expect(apps.apps.isEmpty)
            #expect(!apps.isChoosing)
        }
    }

    @Test func appWithoutABundleIdentifierIsNotAdded() async throws {
        try await withApps { apps, _ in
            for identifier in [nil, "", "  \n"] {
                chooser.chosen = ChosenApp(bundleIdentifier: identifier, name: "Tool")
                #expect(await apps.chooseApp() == .noBundleIdentifier)
            }
            #expect(apps.apps.isEmpty)
        }
    }

    @Test func thisAppIsNotAddedWhateverTheLetterCase() async throws {
        try await withApps { apps, _ in
            for identifier in [Self.ownBundleIdentifier, Self.ownBundleIdentifier.uppercased()] {
                chooser.chosen = ChosenApp(bundleIdentifier: identifier, name: "Show My Copy")
                #expect(await apps.chooseApp() == .thisApp)
            }
            #expect(apps.apps.isEmpty)
            #expect(!apps.excludes(bundleIdentifier: Self.ownBundleIdentifier))
        }
    }

    @Test func appInTheListAlreadyIsKeptAsItWas() async throws {
        try await withApps { apps, _ in
            let existing = try #require(ExcludedApp(bundleIdentifier: "com.apple.TextEdit", name: "TextEdit"))
            apps.add(existing)
            chooser.chosen = ChosenApp(bundleIdentifier: "COM.APPLE.TEXTEDIT", name: "Text Editor")

            #expect(await apps.chooseApp() == .alreadyExcluded(existing))
            #expect(apps.apps == [existing])
        }
    }

    @Test func chosenNameIsSanitizedAndFallsBackToTheBundleIdentifier() async throws {
        try await withApps { apps, _ in
            let spoofed = apps.add(chosen: ChosenApp(bundleIdentifier: "com.example.a", name: "Safe\u{202E}gpj.app\nx"))
            let name = try #require(spoofed.addedName)
            #expect(!name.unicodeScalars.contains("\u{202E}"))
            #expect(!name.contains("\n"))

            let unnamed = apps.add(chosen: ChosenApp(bundleIdentifier: "com.example.b", name: nil))
            #expect(unnamed.addedName == "com.example.b")
        }
    }

    @Test func oneChooserAtATime() async throws {
        try await withApps { apps, _ in
            chooser.chosen = textEdit
            chooser.gate.arm()
            let first = Task { await apps.chooseApp() }
            await chooser.gate.waitUntilReached()

            #expect(apps.isChoosing)
            #expect(await apps.chooseApp() == nil)
            #expect(chooser.count == 1)

            chooser.gate.open()
            let added = try #require(ExcludedApp(bundleIdentifier: "com.apple.TextEdit", name: "TextEdit"))
            #expect(await first.value == .added(added))
            #expect(!apps.isChoosing)
        }
    }

    // MARK: Reading the bundle

    @Test func infoPlistGivesTheIdentifierAndTheDisplayNameFirst() throws {
        let data = try Self.infoPlist([
            "CFBundleIdentifier": "com.apple.TextEdit", "CFBundleName": "TextEdit", "CFBundleDisplayName": "Text Edit",
            "CFBundleExecutable": "TextEdit",
        ])
        let expected = ChosenApp(bundleIdentifier: "com.apple.TextEdit", name: "Text Edit")
        #expect(ChosenApp(infoPlist: data, fileName: "File") == expected)
    }

    @Test func nameFallsBackToTheBundleNameThenTheFileName() throws {
        let named = try Self.infoPlist([
            "CFBundleIdentifier": "com.example.a", "CFBundleName": "Bundle", "CFBundleDisplayName": " ",
        ])
        #expect(ChosenApp(infoPlist: named, fileName: "File").name == "Bundle")

        let unnamed = try Self.infoPlist(["CFBundleIdentifier": "com.example.a", "CFBundleName": 42])
        let expected = ChosenApp(bundleIdentifier: "com.example.a", name: "File")
        #expect(ChosenApp(infoPlist: unnamed, fileName: "File") == expected)
    }

    @Test func unreadableInfoPlistHasNoBundleIdentifier() throws {
        let notADictionary = try PropertyListSerialization.data(
            fromPropertyList: ["com.example.a"], format: .xml, options: 0)
        let wrongType = try Self.infoPlist(["CFBundleIdentifier": 42])
        for data in [nil, Data(), Data("not a property list".utf8), notADictionary, wrongType] {
            let chosen = ChosenApp(infoPlist: data, fileName: "File")
            #expect(chosen.bundleIdentifier == nil)
            #expect(chosen.name == "File")
        }
    }

    @Test func infoPlistOverTheLimitIsNotParsed() throws {
        let padding = String(repeating: "x", count: ChosenApp.maximumInfoPlistBytes)
        let large = try Self.infoPlist(["CFBundleIdentifier": "com.example.a", "Padding": padding])
        #expect(large.count > ChosenApp.maximumInfoPlistBytes)
        #expect(ChosenApp(infoPlist: large, fileName: "File").bundleIdentifier == nil)

        let small = try Self.infoPlist(["CFBundleIdentifier": "com.example.a"])
        #expect(ChosenApp(infoPlist: small, fileName: "File").bundleIdentifier == "com.example.a")
    }
}

extension ChosenAppOutcome {
    fileprivate var addedName: String? {
        if case .added(let app) = self {
            return app.name
        }
        return nil
    }
}
