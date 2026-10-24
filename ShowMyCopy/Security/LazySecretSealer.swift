import Foundation
import Synchronization

/// Creates the real sealer when its key is asked for with `loadKey()`, off the caller's actor, and not before.
///
/// Getting the key can show a Keychain prompt, for example after the app's code signature changed, and the thread
/// that asks waits until the user answers. So the history asks for it with `loadKey()` from a background task, only
/// when a password is saved or a saved one is to be opened, and `seal` and `open` never create the sealer: until it
/// exists they throw `SecretSealingError.keyNotLoaded` at once, so the main thread never waits for the Keychain.
///
/// What the first load found is kept for the session, so the same prompt is not shown over and over:
/// - a sealer that was created is reused;
/// - a locked Mac, or a Keychain that may not ask the user (`interactionNotAllowed`), is tried again by the next
///   `loadKey()`, which the app calls when the user is back at the unlocked Mac;
/// - any other failure, such as the user denying access, is thrown again by every call and tried again only by the
///   next launch.
///
/// Loads asked for at the same time share one: the sealer is created once.
final class LazySecretSealer: SecretSealing {
    typealias Factory = @Sendable () throws(SecretSealingError) -> any SecretSealing

    private enum State {
        case notLoaded
        case loading(Task<SealingKeyState, Never>)
        case loaded(any SecretSealing)
        case failed(SecretSealingError, SealingKeyState)
    }

    private let makeSealer: Factory
    private let state = Mutex(State.notLoaded)

    init(_ makeSealer: @escaping Factory) {
        self.makeSealer = makeSealer
    }

    func seal(_ plaintext: Data) throws -> Data {
        try loadedSealer().seal(plaintext)
    }

    func open(_ sealed: Data) throws -> Data {
        try loadedSealer().open(sealed)
    }

    func loadKey() async -> SealingKeyState {
        let next: LoadStep = state.withLock { state in
            switch state {
            case .loaded:
                return .known(.ready)
            case .failed(_, .unavailable):
                return .known(.unavailable)
            case .loading(let task):
                return .wait(task)
            case .notLoaded, .failed:
                // Created here, under the lock, so loads asked for at the same time share it. It runs on its own,
                // off the caller's actor: the Keychain may wait for the user.
                let task = Task.detached(priority: .userInitiated) { [self] in
                    self.createSealer()
                }
                state = .loading(task)
                return .wait(task)
            }
        }
        switch next {
        case .known(let keyState):
            return keyState
        case .wait(let task):
            return await task.value
        }
    }

    private enum LoadStep {
        case known(SealingKeyState)
        case wait(Task<SealingKeyState, Never>)
    }

    /// Runs the factory without holding the lock, so `seal` and `open` keep answering while it waits for the user.
    private func createSealer() -> SealingKeyState {
        let result: Result<any SecretSealing, SecretSealingError>
        do throws(SecretSealingError) {
            result = .success(try makeSealer())
        } catch {
            result = .failure(error)
        }
        return state.withLock { state in
            switch result {
            case .success(let sealer):
                state = .loaded(sealer)
                return .ready
            case .failure(let error):
                let keyState = Self.keyState(after: error)
                state = .failed(error, keyState)
                return keyState
            }
        }
    }

    /// Only a Keychain that is locked or may not ask now is worth asking again in this session.
    private static func keyState(after error: SecretSealingError) -> SealingKeyState {
        error == .keyUnavailable(.interactionNotAllowed) ? .lockedOut : .unavailable
    }

    /// The sealer, or the reason there is none yet, without waiting.
    private func loadedSealer() throws(SecretSealingError) -> any SecretSealing {
        let result: Result<any SecretSealing, SecretSealingError> = state.withLock { state in
            switch state {
            case .loaded(let sealer):
                .success(sealer)
            case .failed(let error, _):
                .failure(error)
            case .notLoaded, .loading:
                .failure(.keyNotLoaded)
            }
        }
        return try result.get()
    }
}
