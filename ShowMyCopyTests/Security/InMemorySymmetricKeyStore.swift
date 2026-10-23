import Foundation

@testable import ShowMyCopy

/// A key store in memory, with switches for the failures a real keychain can report.
final class InMemorySymmetricKeyStore: SymmetricKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storedKey: Data?
    private var loadError: SymmetricKeyStoreError?
    private var addError: SymmetricKeyStoreError?
    /// Simulates another process adding its key between our load and our add.
    private var keyAddedConcurrently: Data?
    private var addedKeys: [Data] = []
    private var loads = 0

    init(
        key: Data? = nil,
        loadError: SymmetricKeyStoreError? = nil,
        addError: SymmetricKeyStoreError? = nil,
        keyAddedConcurrently: Data? = nil
    ) {
        storedKey = key
        self.loadError = loadError
        self.addError = addError
        self.keyAddedConcurrently = keyAddedConcurrently
    }

    var key: Data? { lock.withLock { storedKey } }
    var added: [Data] { lock.withLock { addedKeys } }
    var loadCount: Int { lock.withLock { loads } }

    func loadKey() throws(SymmetricKeyStoreError) -> Data? {
        let (key, error): (Data?, SymmetricKeyStoreError?) = lock.withLock {
            loads += 1
            return (storedKey, loadError)
        }
        if let error { throw error }
        return key
    }

    func addKey(_ key: Data) throws(SymmetricKeyStoreError) {
        let error: SymmetricKeyStoreError? = lock.withLock {
            if let addError { return addError }
            if let other = keyAddedConcurrently {
                storedKey = other
                keyAddedConcurrently = nil
            }
            if storedKey != nil { return .duplicateItem }
            storedKey = key
            addedKeys.append(key)
            return nil
        }
        if let error { throw error }
    }
}
