import Foundation
import Testing

@testable import ShowMyCopy

/// Counts calls to the key generator; the closure may be called from any thread.
private final class Generator: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let bytes: Data

    init(bytes: Data = Data(repeating: 0x42, count: SealingKey.byteCount)) {
        self.bytes = bytes
    }

    var callCount: Int { lock.withLock { calls } }

    func generate() -> Data {
        lock.withLock { calls += 1 }
        return bytes
    }
}

struct SealingKeyTests {
    private let existingKey = Data(repeating: 0x07, count: 32)

    @Test func keysAre256Bits() {
        #expect(SealingKey.byteCount == 32)
    }

    @Test func validKeyLengthIsAccepted() throws {
        #expect(try SealingKey.validated(existingKey) == existingKey)
    }

    @Test(arguments: [0, 1, 16, 31, 33, 64])
    func otherKeyLengthsAreRejected(length: Int) {
        #expect(throws: SecretSealingError.invalidKeyLength(length)) {
            try SealingKey.validated(Data(repeating: 1, count: length))
        }
    }

    @Test func storedKeyIsLoadedAndNoNewKeyIsMade() throws {
        let store = InMemorySymmetricKeyStore(key: existingKey)
        let generator = Generator()
        let key = try SealingKey.loadOrCreate(in: [store], generate: generator.generate)
        #expect(key == existingKey)
        #expect(generator.callCount == 0)
        #expect(store.added.isEmpty)
    }

    @Test func missingKeyIsCreatedAndStored() throws {
        let store = InMemorySymmetricKeyStore()
        let generator = Generator()
        let key = try SealingKey.loadOrCreate(in: [store], generate: generator.generate)
        #expect(key == Data(repeating: 0x42, count: 32))
        #expect(store.added == [key])
        #expect(generator.callCount == 1)
    }

    @Test func storedKeyOfWrongLengthIsRejectedAndKept() {
        // Never replace a key we did not expect: the data sealed with it would be lost for good.
        let store = InMemorySymmetricKeyStore(key: Data(repeating: 1, count: 16))
        #expect(throws: SecretSealingError.invalidKeyLength(16)) {
            try SealingKey.loadOrCreate(in: [store], generate: Generator().generate)
        }
        #expect(store.key == Data(repeating: 1, count: 16))
        #expect(store.added.isEmpty)
    }

    @Test func generatedKeyOfWrongLengthIsNotStored() {
        let store = InMemorySymmetricKeyStore()
        let generator = Generator(bytes: Data(repeating: 1, count: 31))
        #expect(throws: SecretSealingError.invalidKeyLength(31)) {
            try SealingKey.loadOrCreate(in: [store], generate: generator.generate)
        }
        #expect(store.key == nil)
    }

    @Test func keyAddedByAnotherProcessWinsTheRace() throws {
        let theirs = Data(repeating: 0x99, count: 32)
        let store = InMemorySymmetricKeyStore(keyAddedConcurrently: theirs)
        let key = try SealingKey.loadOrCreate(in: [store], generate: Generator().generate)
        #expect(key == theirs)
        #expect(store.key == theirs)
    }

    @Test func storeWithoutEntitlementFallsBackToTheNextOnLoad() throws {
        let primary = InMemorySymmetricKeyStore(loadError: .missingEntitlement)
        let fallback = InMemorySymmetricKeyStore(key: existingKey)
        let key = try SealingKey.loadOrCreate(in: [primary, fallback], generate: Generator().generate)
        #expect(key == existingKey)
    }

    @Test func storeWithoutEntitlementFallsBackToTheNextOnAdd() throws {
        let primary = InMemorySymmetricKeyStore(addError: .missingEntitlement)
        let fallback = InMemorySymmetricKeyStore()
        let key = try SealingKey.loadOrCreate(in: [primary, fallback], generate: Generator().generate)
        #expect(primary.key == nil)
        #expect(fallback.added == [key])
    }

    @Test func fallbackIsNotUsedWhenTheFirstStoreWorks() throws {
        let primary = InMemorySymmetricKeyStore()
        let fallback = InMemorySymmetricKeyStore(key: existingKey)
        let key = try SealingKey.loadOrCreate(in: [primary, fallback], generate: Generator().generate)
        #expect(key != existingKey)
        #expect(primary.added == [key])
        #expect(fallback.loadCount == 0)
    }

    @Test(arguments: [
        SymmetricKeyStoreError.interactionNotAllowed, .accessDenied, .unexpectedItemData, .unexpectedStatus(-1),
    ])
    func otherLoadErrorsStopWithoutTryingTheFallback(error: SymmetricKeyStoreError) {
        // A key that exists but cannot be read now must not be replaced by a new one in another keychain.
        let primary = InMemorySymmetricKeyStore(loadError: error)
        let fallback = InMemorySymmetricKeyStore()
        #expect(throws: SecretSealingError.keyUnavailable(error)) {
            try SealingKey.loadOrCreate(in: [primary, fallback], generate: Generator().generate)
        }
        #expect(fallback.loadCount == 0)
        #expect(fallback.key == nil)
    }

    @Test func addErrorStopsWithoutTryingTheFallback() {
        let primary = InMemorySymmetricKeyStore(addError: .interactionNotAllowed)
        let fallback = InMemorySymmetricKeyStore()
        #expect(throws: SecretSealingError.keyUnavailable(.interactionNotAllowed)) {
            try SealingKey.loadOrCreate(in: [primary, fallback], generate: Generator().generate)
        }
        #expect(fallback.key == nil)
    }

    @Test func noUsableStoreThrows() {
        let primary = InMemorySymmetricKeyStore(loadError: .missingEntitlement)
        let fallback = InMemorySymmetricKeyStore(addError: .missingEntitlement)
        #expect(throws: SecretSealingError.keyUnavailable(.missingEntitlement)) {
            try SealingKey.loadOrCreate(in: [primary, fallback], generate: Generator().generate)
        }
        #expect(throws: SecretSealingError.keyUnavailable(.missingEntitlement)) {
            try SealingKey.loadOrCreate(in: [], generate: Generator().generate)
        }
    }

    @Test func duplicateThatCannotBeLoadedThrows() {
        // Added by someone else, then gone again before we could read it: give up instead of looping.
        let store = InMemorySymmetricKeyStore(addError: .duplicateItem)
        #expect(throws: SecretSealingError.keyUnavailable(.duplicateItem)) {
            try SealingKey.loadOrCreate(in: [store], generate: Generator().generate)
        }
    }
}
