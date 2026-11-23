import CryptoKit
import Foundation
import Testing

@testable import ShowMyCopy

struct KeychainSecretSealerTests {
    private let secret = Data("correct horse battery staple".utf8)
    private let context = SealingContext.historyEntry(UUID())

    private func makeSealer(store: InMemorySymmetricKeyStore = .init()) throws -> KeychainSecretSealer {
        try KeychainSecretSealer(keyStores: [store])
    }

    @Test func roundTrip() throws {
        let sealer = try makeSealer()
        let sealed = try sealer.seal(secret, boundTo: context)
        #expect(try sealer.open(sealed, boundTo: context) == secret)
    }

    @Test func sealedDataIsVersionNonceCiphertextAndTag() throws {
        let sealed = try makeSealer().seal(secret, boundTo: context)
        #expect(sealed.first == 2)
        #expect(sealed.count == 1 + 12 + secret.count + 16)
        #expect(sealed.range(of: secret) == nil)
    }

    @Test func sealingTheSameSecretTwiceGivesDifferentData() throws {
        // A fresh random nonce for every seal: reusing one with the same key would break AES-GCM.
        let sealer = try makeSealer()
        #expect(try sealer.seal(secret, boundTo: context) != sealer.seal(secret, boundTo: context))
    }

    @Test func emptyPlaintextRoundTrip() throws {
        let sealer = try makeSealer()
        let sealed = try sealer.seal(Data(), boundTo: context)
        #expect(sealed.count == 1 + 12 + 16)
        #expect(try sealer.open(sealed, boundTo: context) == Data())
    }

    @Test func tamperedCiphertextFails() throws {
        let sealer = try makeSealer()
        let sealed = try sealer.seal(secret, boundTo: context)
        for index in sealed.indices.dropFirst() {
            var tampered = sealed
            tampered[index] ^= 0x80
            #expect(throws: SecretSealingError.authenticationFailed) {
                try sealer.open(tampered, boundTo: context)
            }
        }
    }

    @Test func truncatedDataFails() throws {
        let sealer = try makeSealer()
        let sealed = try sealer.seal(secret, boundTo: context)
        #expect(throws: SecretSealingError.authenticationFailed) {
            try sealer.open(sealed.dropLast(), boundTo: context)
        }
        #expect(throws: SecretSealingError.authenticationFailed) {
            try sealer.open(sealed.prefix(10), boundTo: context)
        }
    }

    @Test func wrongKeyFails() throws {
        let sealed = try makeSealer().seal(secret, boundTo: context)
        let other = try makeSealer()
        #expect(throws: SecretSealingError.authenticationFailed) {
            try other.open(sealed, boundTo: context)
        }
    }

    @Test func unknownVersionFails() throws {
        let sealer = try makeSealer()
        var sealed = try sealer.seal(secret, boundTo: context)
        sealed[sealed.startIndex] = 3
        #expect(throws: SecretSealingError.newerFormatVersion(3)) {
            try sealer.open(sealed, boundTo: context)
        }
        sealed[sealed.startIndex] = 0
        #expect(throws: SecretSealingError.unsupportedFormatVersion(0)) {
            try sealer.open(sealed, boundTo: context)
        }
        #expect(throws: SecretSealingError.missingFormatVersion) {
            try sealer.open(Data(), boundTo: context)
        }
    }

    // MARK: - Key store

    @Test func newKeyIsStoredAndReusedByTheNextSealer() throws {
        let store = InMemorySymmetricKeyStore()
        let sealed = try makeSealer(store: store).seal(secret, boundTo: context)
        #expect(store.added.count == 1)
        #expect(store.key?.count == 32)

        let next = try makeSealer(store: store)
        #expect(try next.open(sealed, boundTo: context) == secret)
        #expect(store.added.count == 1)
    }

    @Test func storedKeyIsUsedForAESGCM() throws {
        let keyData = Data((0..<32).map { UInt8($0) })
        let sealed = try makeSealer(store: InMemorySymmetricKeyStore(key: keyData)).seal(secret, boundTo: context)
        let box = try AES.GCM.SealedBox(combined: sealed.dropFirst())
        let opened = try AES.GCM.open(
            box, using: SymmetricKey(data: keyData), authenticating: Data([2]) + context.bytes)
        #expect(opened == secret)
    }

    @Test func dataSealedByAnEarlierVersionStillOpens() throws {
        // 0.1.0 and 0.2.0 sealed with the version byte alone authenticated (format version 1).
        let keyData = Data((0..<32).map { UInt8($0) })
        let key = SymmetricKey(data: keyData)
        let box = try AES.GCM.seal(secret, using: key, authenticating: Data([1]))
        let sealed = Data([1]) + (try #require(box.combined))
        let sealer = try makeSealer(store: InMemorySymmetricKeyStore(key: keyData))
        #expect(try sealer.open(sealed, boundTo: context) == secret)
        #expect(try sealer.open(sealed, boundTo: .codeAccounts) == secret)
    }

    @Test func dataBoundToAnotherRecordFailsAuthentication() throws {
        let sealer = try makeSealer()
        let sealed = try sealer.seal(secret, boundTo: context)
        #expect(throws: SecretSealingError.authenticationFailed) {
            try sealer.open(sealed, boundTo: .historyEntry(UUID()))
        }
        #expect(throws: SecretSealingError.authenticationFailed) {
            try sealer.open(sealed, boundTo: .codeAccounts)
        }
    }

    @Test func unavailableKeyStoreThrowsATypedError() {
        let store = InMemorySymmetricKeyStore(loadError: .interactionNotAllowed)
        #expect(throws: SecretSealingError.keyUnavailable(.interactionNotAllowed)) {
            try makeSealer(store: store)
        }
    }

    @Test func storedKeyOfWrongLengthThrows() {
        let store = InMemorySymmetricKeyStore(key: Data(repeating: 1, count: 16))
        #expect(throws: SecretSealingError.invalidKeyLength(16)) {
            try makeSealer(store: store)
        }
    }

    @Test func appKeychainItemIsNamedForTheHistoryKey() {
        let stores = KeychainSymmetricKeyStore.stores(
            service: KeychainSecretSealer.service, account: KeychainSecretSealer.account)
        #expect(stores.map(\.backend) == [.dataProtection, .fileBased])
        #expect(KeychainSecretSealer.service == "com.pandamy619.ShowMyCopy.history-key")
        #expect(KeychainSecretSealer.account == "history-encryption-key")
    }

    // MARK: - Real Keychain (optional)

    /// Uses the real Keychain under a test-only service name and deletes the item afterwards. Disabled, with this
    /// message in the test report, when the test host cannot add and delete a keychain item.
    @Test(
        .enabled("Keychain unavailable in this test host; real Keychain test skipped") {
            KeychainTestItem.canUseKeychain()
        }
    )
    func realKeychainRoundTrip() throws {
        let item = KeychainTestItem()
        defer {
            do {
                try item.delete()
            } catch {
                Issue.record("Could not delete the test Keychain item: \(error)")
            }
        }

        let sealed = try KeychainSecretSealer(keyStores: item.stores).seal(secret, boundTo: context)
        // A second sealer must find the same key in the Keychain instead of creating another one.
        let reopened = try KeychainSecretSealer(keyStores: item.stores)
        #expect(try reopened.open(sealed, boundTo: context) == secret)
    }
}

/// A Keychain item under a unique, test-only service name, in whichever keychain this test host may use.
private struct KeychainTestItem {
    let stores = KeychainSymmetricKeyStore.stores(
        service: "com.pandamy619.ShowMyCopy.tests.\(UUID().uuidString)", account: "test-key")

    func delete() throws(SymmetricKeyStoreError) {
        for store in stores {
            do {
                try store.deleteKey()
            } catch .missingEntitlement {
                // Not entitled to this keychain, so nothing was added there.
                continue
            }
        }
    }

    /// Adds and deletes a probe item, so the real test runs only where the Keychain works.
    static func canUseKeychain() -> Bool {
        let probe = KeychainTestItem()
        do {
            _ = try SealingKey.loadOrCreate(in: probe.stores) { Data(repeating: 0, count: SealingKey.byteCount) }
            try probe.delete()
            return true
        } catch {
            return false
        }
    }
}
