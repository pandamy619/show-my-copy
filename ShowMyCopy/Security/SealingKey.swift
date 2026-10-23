import Foundation

/// Loading and creating the key that seals secrets saved on disk.
enum SealingKey {
    /// 256-bit keys, for AES-256-GCM.
    static let byteCount = 32

    static func validated(_ key: Data) throws(SecretSealingError) -> Data {
        guard key.count == byteCount else { throw .invalidKeyLength(key.count) }
        return key
    }

    /// Returns the stored key, or creates, stores and returns a new one.
    ///
    /// `stores` are tried in order. A store is skipped only when this build is not entitled to use it at all
    /// (`.missingEntitlement`). Any other error stops the search: the key may exist but be unreadable right now
    /// (locked Mac, access denied), and a new key elsewhere would silently orphan everything sealed with it.
    /// A stored key of the wrong length is rejected and left in place for the same reason.
    static func loadOrCreate(
        in stores: [any SymmetricKeyStore],
        generate: () -> Data
    ) throws(SecretSealingError) -> Data {
        for store in stores {
            do {
                return try loadOrCreate(in: store, generate: generate)
            } catch {
                switch error {
                case .store(.missingEntitlement): continue
                case .store(let storeError): throw .keyUnavailable(storeError)
                case .sealing(let keyError): throw keyError
                }
            }
        }
        throw .keyUnavailable(.missingEntitlement)
    }

    private static func loadOrCreate(
        in store: any SymmetricKeyStore,
        generate: () -> Data
    ) throws(KeyStoreFailure) -> Data {
        if let key = try load(from: store) { return key }
        let key = try validatedNewKey(generate())
        do {
            try store.addKey(key)
            return key
        } catch .duplicateItem {
            // Another instance added its key between our load and our add: use theirs.
            guard let key = try load(from: store) else { throw .store(.duplicateItem) }
            return key
        } catch {
            throw .store(error)
        }
    }

    private static func load(from store: any SymmetricKeyStore) throws(KeyStoreFailure) -> Data? {
        let key: Data?
        do {
            key = try store.loadKey()
        } catch {
            throw .store(error)
        }
        guard let key else { return nil }
        do {
            return try validated(key)
        } catch {
            throw .sealing(error)
        }
    }

    private static func validatedNewKey(_ key: Data) throws(KeyStoreFailure) -> Data {
        do {
            return try validated(key)
        } catch {
            throw .sealing(error)
        }
    }
}

/// Internal to `SealingKey`: keeps store errors apart from key errors until the store loop decides what to do.
private enum KeyStoreFailure: Error {
    case store(SymmetricKeyStoreError)
    case sealing(SecretSealingError)
}
