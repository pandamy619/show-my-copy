import Foundation
import Testing

@testable import ShowMyCopy

@MainActor
struct ExcludedAppsTests {
    private let running = FakeRunningApps()

    private func app(_ bundleIdentifier: String, _ name: String) throws -> ExcludedApp {
        try #require(ExcludedApp(bundleIdentifier: bundleIdentifier, name: name))
    }

    @Test func nothingIsExcludedAtFirst() throws {
        try TestDefaults.with { defaults in
            let apps = ExcludedApps(defaults: defaults, running: running)
            #expect(apps.apps.isEmpty)
            #expect(!apps.excludes(bundleIdentifier: "com.apple.TextEdit"))
            #expect(!apps.excludes(bundleIdentifier: nil))
        }
    }

    @Test func addedAppIsExcludedWithoutRegardToLetterCase() throws {
        try TestDefaults.with { defaults in
            let apps = ExcludedApps(defaults: defaults, running: running)
            apps.add(try app("com.apple.TextEdit", "TextEdit"))

            #expect(apps.excludes(bundleIdentifier: "com.apple.TextEdit"))
            #expect(apps.excludes(bundleIdentifier: "COM.APPLE.TEXTEDIT"))
            #expect(!apps.excludes(bundleIdentifier: "com.apple.Notes"))
        }
    }

    @Test func listSurvivesARelaunch() throws {
        try TestDefaults.with { defaults in
            let apps = ExcludedApps(defaults: defaults, running: running)
            apps.add(try app("com.apple.TextEdit", "TextEdit"))
            apps.add(try app("com.apple.Notes", "Notes"))

            let relaunched = ExcludedApps(defaults: defaults, running: running)

            #expect(relaunched.apps.map(\.name) == ["Notes", "TextEdit"])
            #expect(relaunched.apps.map(\.bundleIdentifier) == ["com.apple.Notes", "com.apple.TextEdit"])
            #expect(relaunched.excludes(bundleIdentifier: "com.apple.textedit"))
        }
    }

    @Test func removedAppIsRecordedAgainAfterARelaunch() throws {
        try TestDefaults.with { defaults in
            let apps = ExcludedApps(defaults: defaults, running: running)
            let textEdit = try app("com.apple.TextEdit", "TextEdit")
            apps.add(textEdit)
            apps.add(try app("com.apple.Notes", "Notes"))

            apps.remove(textEdit)

            #expect(!apps.excludes(bundleIdentifier: "com.apple.TextEdit"))
            #expect(apps.apps.map(\.name) == ["Notes"])
            #expect(ExcludedApps(defaults: defaults, running: running).apps.map(\.name) == ["Notes"])
        }
    }

    @Test func addingAnAppTwiceKeepsOneEntry() throws {
        try TestDefaults.with { defaults in
            let apps = ExcludedApps(defaults: defaults, running: running)
            apps.add(try app("com.apple.TextEdit", "TextEdit"))
            apps.add(try app("COM.APPLE.TEXTEDIT", "Text Edit"))

            #expect(apps.apps.map(\.name) == ["TextEdit"])
        }
    }

    @Test func listIsSortedByName() throws {
        try TestDefaults.with { defaults in
            let apps = ExcludedApps(defaults: defaults, running: running)
            apps.add(try app("com.apple.TextEdit", "TextEdit"))
            apps.add(try app("com.example.zed", "zed"))
            apps.add(try app("com.apple.Notes", "notes"))

            #expect(apps.apps.map(\.name) == ["notes", "TextEdit", "zed"])
        }
    }

    @Test func damagedSavedEntriesAreLeftOut() throws {
        try TestDefaults.with { defaults in
            defaults.set(
                [
                    ["bundleIdentifier": "com.apple.TextEdit", "name": "TextEdit"],
                    "not a dictionary",
                    ["name": "No identifier"],
                    ["bundleIdentifier": "  ", "name": "Blank identifier"],
                    ["bundleIdentifier": 42, "name": "Not a string"],
                    ["bundleIdentifier": "com.apple.textedit", "name": "Repeated"],
                    ["bundleIdentifier": "com.apple.Notes"],
                ] as [Any],
                forKey: SettingsKey.excludedApps)

            let apps = ExcludedApps(defaults: defaults, running: running)

            #expect(apps.apps.map(\.name) == ["com.apple.Notes", "TextEdit"])
        }
    }

    @Test func savedValueOfAnotherTypeMeansNoApps() throws {
        try TestDefaults.with { defaults in
            defaults.set("com.apple.TextEdit", forKey: SettingsKey.excludedApps)
            #expect(ExcludedApps(defaults: defaults, running: running).apps.isEmpty)
        }
    }

    // MARK: Apps

    @Test func appNeedsABundleIdentifier() {
        #expect(ExcludedApp(bundleIdentifier: nil, name: "Tool") == nil)
        #expect(ExcludedApp(bundleIdentifier: "", name: "Tool") == nil)
        #expect(ExcludedApp(SourceApp(bundleIdentifier: nil, name: "Tool")) == nil)
    }

    @Test func nameIsSanitizedAndFallsBackToTheBundleIdentifier() throws {
        let spoofed = try app("com.example.app", "Safe\u{202E}txt.exe\u{0007}\nsecond line")
        #expect(!spoofed.name.unicodeScalars.contains("\u{202E}"))
        #expect(!spoofed.name.unicodeScalars.contains("\u{0007}"))
        #expect(!spoofed.name.contains("\n"))

        #expect(ExcludedApp(bundleIdentifier: "com.example.app", name: nil)?.name == "com.example.app")
        #expect(ExcludedApp(bundleIdentifier: "com.example.app", name: "\u{0007}")?.name == "com.example.app")
    }

    // MARK: Open apps

    @Test func openAppsCanBeAddedOnceEachWithoutThoseExcludedAlready() throws {
        try TestDefaults.with { defaults in
            running.apps = [
                SourceApp(bundleIdentifier: "com.apple.TextEdit", name: "TextEdit"),
                SourceApp(bundleIdentifier: "com.apple.Safari", name: "Safari"),
                SourceApp(bundleIdentifier: nil, name: "No identifier"),
                SourceApp(bundleIdentifier: "com.apple.safari", name: "Safari again"),
                SourceApp(bundleIdentifier: "com.apple.Notes", name: "Notes"),
            ]
            let apps = ExcludedApps(defaults: defaults, running: running)
            apps.add(try app("com.apple.TextEdit", "TextEdit"))

            #expect(apps.addableApps().map(\.name) == ["Notes", "Safari"])

            apps.add(try #require(apps.addableApps().first))
            #expect(apps.addableApps().map(\.name) == ["Safari"])
        }
    }
}
