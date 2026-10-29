import AppKit
import Testing

@testable import ShowMyCopy

@MainActor
struct WorkspaceRunningAppsTests {
    @Test func listsFinderButNotThisProcess() {
        let apps = WorkspaceRunningApps().runningApps()

        #expect(apps.contains { $0.bundleIdentifier?.lowercased() == "com.apple.finder" })
        let own = NSRunningApplication.current
        #expect(!apps.contains { $0.bundleIdentifier != nil && $0.bundleIdentifier == own.bundleIdentifier })
    }

    @Test func leavesOutAppsWithoutADockIcon() {
        let regular = Set(
            NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
                .compactMap(\.bundleIdentifier))

        let listed = WorkspaceRunningApps().runningApps().compactMap(\.bundleIdentifier)

        #expect(listed.allSatisfy { regular.contains($0) })
    }

    @Test func finderCanBeAddedFromTheOpenApps() throws {
        try TestDefaults.with { defaults in
            let apps = ExcludedApps(defaults: defaults, running: WorkspaceRunningApps())
            let finder = try #require(apps.addableApps().first { $0.id == "com.apple.finder" })

            apps.add(finder)

            #expect(apps.excludes(bundleIdentifier: "com.apple.finder"))
            #expect(!apps.addableApps().contains { $0.id == "com.apple.finder" })
        }
    }
}

@MainActor
struct ApplicationIconTests {
    @Test func installedAppHasAnIcon() {
        let icon = ApplicationIcon.icon(forBundleIdentifier: "com.apple.finder")
        #expect(icon.isValid)
        #expect(icon.size.width > 0)
    }

    @Test func unknownAppGetsTheGenericIcon() {
        let icon = ApplicationIcon.icon(forBundleIdentifier: "com.example.not-installed-\(UUID().uuidString)")
        #expect(icon.isValid)
    }

    @Test func appOffTheStartupDiskIsNotLookedAt() {
        // Without a mount list every path counts as remote: the generic icon comes back, the path is not touched.
        let icon = ApplicationIcon.icon(
            forBundleIdentifier: "com.apple.finder", paths: CopiedPaths(volumes: FakeVolumes(nil)))
        #expect(icon.isValid)
    }
}
