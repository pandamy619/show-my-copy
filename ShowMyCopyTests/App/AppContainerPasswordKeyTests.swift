import AppKit
import Foundation
import Testing

@testable import ShowMyCopy

/// Saved passwords wait on disk until the key loads in the background: started at launch, and tried again when the
/// user comes back to an unlocked Mac.
@MainActor
struct AppContainerPasswordKeyTests {
    private let disk = FakeHistoryPersistence()
    private let distributed = FakeNotifications()
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func withContainer(
        store: PersistentHistoryStore,
        _ body: @MainActor (AppContainer) async throws -> Void
    ) async throws {
        let suiteName = "ShowMyCopyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: SettingsKey.savePasswords)
        let services = ContainerFactory.services(now: { [start] in start }, distributed: distributed)
        let container = AppContainer(history: AppHistory(store), services: services, defaults: defaults)
        defer { container.monitor.stop() }
        try await body(container)
    }

    private func savePassword() -> UUID {
        disk.makeStore(now: start).record(
            text: "hunter2", sourceApp: nil, at: start, concealed: true, expiresAt: start + 600)
    }

    @Test func startLoadsTheKeyInTheBackgroundAndOpensSavedPasswords() async throws {
        let id = savePassword()
        let sealer = KeyTroubleSealer()
        sealer.gate.arm()
        let store = disk.makeStore(sealer: sealer, now: start + 1)

        try await withContainer(store: store) { container in
            container.start()
            // The launch went on without the key: the load waits at the gate.
            await sealer.gate.waitUntilReached()
            #expect(store.entries.allSatisfy { $0.id != id })

            sealer.gate.open()
            await store.loadPasswordKey()
            #expect(store.entries.contains { $0.id == id })
        }
    }

    @Test func unlockingTheMacTriesTheKeyAgain() async throws {
        let id = savePassword()
        let sealer = KeyTroubleSealer(failure: .keyUnavailable(.interactionNotAllowed), loadedState: .lockedOut)
        let store = disk.makeStore(sealer: sealer, now: start + 1)

        try await withContainer(store: store) { container in
            sealer.gate.arm()
            container.start()
            await sealer.gate.waitUntilReached()
            sealer.gate.open()
            await store.loadPasswordKey()
            #expect(store.entries.allSatisfy { $0.id != id })

            sealer.setLoadedState(.ready)
            sealer.gate.arm()
            distributed.post(SystemActivityObserver.screenIsUnlockedNotification)
            // Reached only by a load the unlock started.
            await sealer.gate.waitUntilReached()

            sealer.gate.open()
            await store.loadPasswordKey()
            #expect(store.entries.contains { $0.id == id })
        }
    }
}
