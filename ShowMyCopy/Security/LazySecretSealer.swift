import Foundation
import Synchronization

/// Creates the real sealer on the first `seal` or `open`, not before.
///
/// Getting the key can show a Keychain prompt, for example after the app's code signature changed. Most users never
/// save passwords, so the key is asked for only when a password is saved or a saved one is loaded.
///
/// The first result is kept for the session: a sealer that was created is reused, and a failure is thrown again on
/// every later call without asking the Keychain again. Retrying on each copy could show the same prompt over and
/// over; quitting and opening the app tries again.
///
/// Calls from several threads at once create the sealer once: the others wait for it.
final class LazySecretSealer: SecretSealing {
    typealias Factory = @Sendable () throws -> any SecretSealing

    private enum State {
        case notCreated(Factory)
        case created(any SecretSealing)
        case failed(any Error)
    }

    private let state: Mutex<State>

    init(_ makeSealer: @escaping Factory) {
        state = Mutex(.notCreated(makeSealer))
    }

    func seal(_ plaintext: Data) throws -> Data {
        try sealer().seal(plaintext)
    }

    func open(_ sealed: Data) throws -> Data {
        try sealer().open(sealed)
    }

    /// The real sealer, created on the first call. The lock is held while it is created, so a slow Keychain makes
    /// other callers wait instead of creating a second one.
    private func sealer() throws -> any SecretSealing {
        let result: Result<any SecretSealing, any Error> = state.withLock { state in
            switch state {
            case .created(let sealer):
                return .success(sealer)
            case .failed(let error):
                return .failure(error)
            case .notCreated(let makeSealer):
                do {
                    let sealer = try makeSealer()
                    state = .created(sealer)
                    return .success(sealer)
                } catch {
                    state = .failed(error)
                    return .failure(error)
                }
            }
        }
        return try result.get()
    }
}
