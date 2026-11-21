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
    /// Every store is searched, in order, before a key is made anywhere: a key in a later store (the login keychain,
    /// from before a build could use the data protection keychain) must go on being used, or everything sealed with
    /// it is silently orphaned. A new key goes in the first store that takes it. A store is skipped only when this
    /// build is not entitled to use it at all (`.missingEntitlement`). Any other error stops the search: the key may
    /// exist but be unreadable right now (locked Mac, access denied), and a new key elsewhere would orphan
    /// everything sealed with it. A stored key of the wrong length is rejected and left in place for the same reason.
    static func loadOrCreate(
        in stores: [any SymmetricKeyStore],
        generate: () -> Data
    ) throws(SecretSealingError) -> Data {
        var usable: [any SymmetricKeyStore] = []
        for store in stores {
            do {
                if let key = try load(from: store) { return key }
                usable.append(store)
            } catch {
                try skipOrRethrow(error)
            }
        }
        for store in usable {
            do {
                return try create(in: store, generate: generate)
            } catch {
                try skipOrRethrow(error)
            }
        }
        throw .keyUnavailable(.missingEntitlement)
    }

    /// Returns for a store this build may not use, so the next one is tried; any other failure ends the search.
    private static func skipOrRethrow(_ error: KeyStoreFailure) throws(SecretSealingError) {
        switch error {
        case .store(.missingEntitlement): return
        case .store(let storeError): throw .keyUnavailable(storeError)
        case .sealing(let keyError): throw keyError
        }
    }

    private static func create(
        in store: any SymmetricKeyStore,
        generate: () -> Data
    ) throws(KeyStoreFailure) -> Data {
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
