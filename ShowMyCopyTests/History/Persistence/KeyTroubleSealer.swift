import Foundation
import Synchronization

@testable import ShowMyCopy

/// A sealer whose key may not be usable, like the Keychain-backed one: until its key is loaded, `seal` and `open`
/// throw `failure`. `loadKey()` gives `loadedState`; when that is `.ready`, the sealer works like `FakeSecretSealer`
/// from then on. Counts the loads and can hold them at `gate`.
final class KeyTroubleSealer: SecretSealing {
    private struct State {
        var failure: SecretSealingError
        var loadedState: SealingKeyState
        var isReady = false
        var loadCount = 0
    }

    private let state: Mutex<State>
    private let sealer = FakeSecretSealer()
    let gate = AsyncGate()

    init(failure: SecretSealingError = .keyNotLoaded, loadedState: SealingKeyState = .ready) {
        state = Mutex(State(failure: failure, loadedState: loadedState))
    }

    var loadCount: Int {
        state.withLock { $0.loadCount }
    }

    /// What the next `loadKey()` gives, such as `.ready` once the Mac is unlocked.
    func setLoadedState(_ loadedState: SealingKeyState) {
        state.withLock { $0.loadedState = loadedState }
    }

    func seal(_ plaintext: Data) throws -> Data {
        try readySealer().seal(plaintext)
    }

    func open(_ sealed: Data) throws -> Data {
        try readySealer().open(sealed)
    }

    func loadKey() async -> SealingKeyState {
        state.withLock { $0.loadCount += 1 }
        await gate.pass()
        return state.withLock { state in
            if state.loadedState == .ready {
                state.isReady = true
            }
            return state.loadedState
        }
    }

    private func readySealer() throws -> FakeSecretSealer {
        let failure: SecretSealingError? = state.withLock { $0.isReady ? nil : $0.failure }
        if let failure {
            throw failure
        }
        return sealer
    }
}

/// Opens sealed data with `FakeSecretSealer` but fails every open with `error`, as data that was damaged, sealed
/// with another key or in another format does with a key that loaded fine.
struct DataTroubleSealer: SecretSealing {
    let error: SecretSealingError

    func seal(_ plaintext: Data) throws -> Data {
        try FakeSecretSealer().seal(plaintext)
    }

    func open(_ sealed: Data) throws -> Data {
        throw error
    }
}
