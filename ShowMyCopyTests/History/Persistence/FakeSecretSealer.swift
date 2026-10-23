import Foundation

@testable import ShowMyCopy

struct FakeSealingError: Error {}

/// Stands in for the Keychain-backed sealer. Not encryption: it flips every byte with `key` and puts the key first,
/// so a test can see that the stored bytes are not the plaintext, and opening data sealed with another key fails
/// like a lost or replaced key does.
struct FakeSecretSealer: SecretSealing {
    var key: UInt8 = 0x5A
    /// Makes `seal` throw, like a Keychain that cannot be reached.
    var failsToSeal = false

    func seal(_ plaintext: Data) throws -> Data {
        guard !failsToSeal else {
            throw FakeSealingError()
        }
        return Data([key] + plaintext.map { $0 ^ key })
    }

    func open(_ sealed: Data) throws -> Data {
        guard let first = sealed.first, first == key else {
            throw FakeSealingError()
        }
        return Data(sealed.dropFirst().map { $0 ^ key })
    }
}
