import AppKit
import Foundation
import Testing

@testable import ShowMyCopy

/// The owner's sequence across launches: copies are made, the app quits through its termination path, and a new
/// app starts on the same saved records with something still on the pasteboard. Every launch builds a new store and
/// container on the same `FakeHistoryPersistence` and blob store, like a new process on the same files.
@MainActor
struct AppRelaunchTests {
    private let records = FakeHistoryPersistence()
    private let base = InMemoryBlobStore()
    private let pasteboard = FakePasteboard()
    private let clock = ManualDate(ContainerFactory.date)
    private let textEdit = SourceApp(bundleIdentifier: "com.apple.TextEdit", name: "TextEdit")

    /// The app's parts on the saved records, without starting them.
    private func makeContainer(defaults: UserDefaults) -> (AppContainer, PersistentHistoryStore) {
        let blobs = InFlightBlobStore(base: base)
        let store = PersistentHistoryStore.loadedNow(
            persistence: records, sealer: FakeSecretSealer(), savesPasswords: true, now: clock.now,
            clock: clock.read, blobs: blobs)
        let media = AppServices.Media(blobs: blobs, thumbnails: FakeThumbnailMaker())
        let services = ContainerFactory.services(
            pasteboard: pasteboard, now: clock.read, frontmostApp: { [textEdit] in textEdit }, media: media)
        return (AppContainer(history: AppHistory(store), services: services, defaults: defaults), store)
    }

    /// One run of the app: loads the saved history, starts, lets `body` copy, then quits the way the app does.
    private func launch(
        defaults: UserDefaults,
        _ body: (AppContainer) async throws -> Void = { _ in }
    ) async throws -> PersistentHistoryStore {
        let (container, store) = makeContainer(defaults: defaults)
        container.start()
        await container.finishCapturing(within: AppContainer.quitBudget)
        try await body(container)
        // `applicationShouldTerminate`: wait for what is still being saved, then the process ends.
        await container.finishCapturing(within: AppContainer.quitBudget)
        container.monitor.stop()
        return store
    }

    /// A copy made while the app runs, a few seconds after the one before.
    private func copy(_ container: AppContainer, _ write: (FakePasteboard) -> Void) async {
        clock.advance(by: 5)
        write(pasteboard)
        container.monitor.poll()
        await container.monitor.finishEnriching()
    }

    private func expectNoDuplicates(in store: PersistentHistoryStore, count: Int) {
        #expect(store.entries.count == count)
        #expect(Set(store.entries.map(\.contentHash)).count == count)
        #expect(Set(store.entries.map(\.id)).count == count)
        #expect(records.records.count == count)
        #expect(Set(records.records.values.compactMap(\.contentHash)).count == count)
    }

    /// Copy A, copy B, quit, launch with B still on the pasteboard, quit, launch again.
    private func relaunchTwice(
        copyA: (FakePasteboard) -> Void,
        copyB: (FakePasteboard) -> Void,
        onPasteboardAtRelaunch: ((FakePasteboard) -> Void)? = nil
    ) async throws {
        try await ContainerFactory.withDefaults { defaults in
            let first = try await launch(defaults: defaults) { container in
                await copy(container, copyA)
                await copy(container, copyB)
            }
            expectNoDuplicates(in: first, count: 2)
            let saved = first.entries

            if let onPasteboardAtRelaunch {
                clock.advance(by: 60)
                onPasteboardAtRelaunch(pasteboard)
            }
            clock.advance(by: 60)
            let second = try await launch(defaults: defaults)
            expectNoDuplicates(in: second, count: 2)
            if onPasteboardAtRelaunch == nil {
                #expect(second.entries.map(\.id) == saved.map(\.id))
            }

            clock.advance(by: 60)
            let third = try await launch(defaults: defaults)
            expectNoDuplicates(in: third, count: 2)
        }
    }

    @Test func plainTextCopiedBeforeQuittingIsListedOnceAfterRelaunch() async throws {
        try await relaunchTwice(copyA: { $0.copy("alpha") }, copyB: { $0.copy("beta") })
    }

    @Test func olderTextOnThePasteboardAtRelaunchIsListedOnce() async throws {
        try await relaunchTwice(
            copyA: { $0.copy("alpha") }, copyB: { $0.copy("beta") }, onPasteboardAtRelaunch: { $0.copy("alpha") })
    }

    @Test func richTextCopiedBeforeQuittingIsListedOnceAfterRelaunch() async throws {
        try await relaunchTwice(
            copyA: { $0.copyRichText("alpha\r\nline") },
            copyB: { $0.copyRichText("Beta café", rtf: Data(#"{\rtf1 \b Beta}"#.utf8)) })
    }

    @Test func filesCopiedBeforeQuittingAreListedOnceAfterRelaunch() async throws {
        try await relaunchTwice(
            copyA: { $0.copyFiles([URL(filePath: "/Users/me/Report final.pdf")]) },
            copyB: { $0.copyFiles([URL(filePath: "/Users/me/Folder", directoryHint: .isDirectory)]) })
    }

    @Test func imageCopiedBeforeQuittingIsListedOnceAfterRelaunch() async throws {
        try await relaunchTwice(
            copyA: { $0.copy("alpha") }, copyB: { $0.copy([.png: Data([0x89, 0x50, 0x4E, 0x47])]) })
    }

    @Test func olderImageOnThePasteboardAtRelaunchIsListedOnce() async throws {
        try await relaunchTwice(
            copyA: { $0.copy([.png: Data([0x89, 0x50, 0x4E, 0x47])]) }, copyB: { $0.copy("beta") },
            onPasteboardAtRelaunch: { $0.copy([.png: Data([0x89, 0x50, 0x4E, 0x47])]) })
    }

    /// Two processes of the app on one saved history, such as a build started from Xcode while the installed one
    /// runs (the app has no Dock or menu bar icon, so the other one is easy to miss): each records every copy under
    /// its own ID, so the disk holds every entry twice. The next launch lists each once and deletes the copies.
    @Test func entriesSavedTwiceByTwoRunningAppsAreListedOnceAfterRelaunch() async throws {
        try await ContainerFactory.withDefaults { defaults in
            let (first, firstStore) = makeContainer(defaults: defaults)
            let (second, secondStore) = makeContainer(defaults: defaults)
            first.start()
            second.start()
            for text in ["alpha", "beta"] {
                clock.advance(by: 5)
                pasteboard.copy(text)
                first.monitor.poll()
                clock.advance(by: 1)
                second.monitor.poll()
            }
            first.monitor.stop()
            second.monitor.stop()
            #expect(firstStore.entries.count == 2 && secondStore.entries.count == 2)
            #expect(records.records.count == 4)
            let newest = Set(secondStore.entries.map(\.id))

            clock.advance(by: 60)
            let relaunched = try await launch(defaults: defaults)
            expectNoDuplicates(in: relaunched, count: 2)
            #expect(relaunched.entries.map(\.text) == ["beta", "alpha"])
            #expect(Set(relaunched.entries.map(\.id)) == newest)
            // One transaction deleted the copies.
            #expect(records.changes.filter { !$0.deleted.isEmpty }.count == 1)

            let again = try await launch(defaults: defaults)
            expectNoDuplicates(in: again, count: 2)
        }
    }
}
