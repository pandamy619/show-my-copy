import Foundation
import Synchronization
import Testing

@testable import ShowMyCopy

/// Makes sealers and counts how often it was asked to, from any thread. Fails with `failure` when one is given, and
/// remembers whether it ran on the main thread.
final class SealerFactorySpy: Sendable {
    private struct State {
        var calls = 0
        var failure: SecretSealingError?
        var ranOnMainThread = false
    }

    private let state: Mutex<State>

    init(fails: Bool = false) {
        state = Mutex(State(failure: fails ? .keyUnavailable(.accessDenied) : nil))
    }

    init(failure: SecretSealingError?) {
        state = Mutex(State(failure: failure))
    }

    var calls: Int {
        state.withLock { $0.calls }
    }

    var ranOnMainThread: Bool {
        state.withLock { $0.ranOnMainThread }
    }

    /// Makes the next calls fail with `failure`, or succeed with nil.
    func setFailure(_ failure: SecretSealingError?) {
        state.withLock { $0.failure = failure }
    }

    func make() throws(SecretSealingError) -> any SecretSealing {
        let isMainThread = Thread.isMainThread
        let failure = state.withLock { state in
            state.calls += 1
            state.ranOnMainThread = state.ranOnMainThread || isMainThread
            return state.failure
        }
        if let failure {
            throw failure
        }
        return FakeSecretSealer()
    }

    func makeLazySealer() -> LazySecretSealer {
        LazySecretSealer { [self] () throws(SecretSealingError) -> any SecretSealing in try make() }
    }
}

struct LazySecretSealerTests {
    private let secret = Data("hunter2".utf8)

    @Test func doesNotCreateTheSealerUntilItsKeyIsLoaded() {
        let factory = SealerFactorySpy()
        let sealer = factory.makeLazySealer()

        #expect(throws: SecretSealingError.keyNotLoaded) {
            try sealer.seal(secret)
        }
        #expect(throws: SecretSealingError.keyNotLoaded) {
            try sealer.open(secret)
        }
        #expect(factory.calls == 0)
    }

    @MainActor
    @Test func loadsTheKeyOffTheMainThreadOnceAndKeepsIt() async throws {
        let factory = SealerFactorySpy()
        let sealer = factory.makeLazySealer()

        #expect(await sealer.loadKey() == .ready)
        let sealed = try sealer.seal(secret)
        #expect(sealed != secret)
        #expect(try sealer.open(sealed) == secret)
        #expect(await sealer.loadKey() == .ready)

        #expect(factory.calls == 1)
        #expect(!factory.ranOnMainThread)
    }

    @Test func remembersADenialForTheRestOfTheSession() async {
        let factory = SealerFactorySpy(failure: .keyUnavailable(.accessDenied))
        let sealer = factory.makeLazySealer()

        #expect(await sealer.loadKey() == .unavailable)
        #expect(throws: SecretSealingError.keyUnavailable(.accessDenied)) {
            try sealer.seal(secret)
        }
        // Asking again would show the same prompt again: the next launch tries again.
        factory.setFailure(nil)
        #expect(await sealer.loadKey() == .unavailable)
        #expect(throws: SecretSealingError.keyUnavailable(.accessDenied)) {
            try sealer.open(secret)
        }
        #expect(factory.calls == 1)
    }

    @Test func triesAgainAfterTheKeychainWasLocked() async throws {
        let factory = SealerFactorySpy(failure: .keyUnavailable(.interactionNotAllowed))
        let sealer = factory.makeLazySealer()

        #expect(await sealer.loadKey() == .lockedOut)
        #expect(throws: SecretSealingError.keyUnavailable(.interactionNotAllowed)) {
            try sealer.seal(secret)
        }

        factory.setFailure(nil)
        #expect(await sealer.loadKey() == .ready)
        #expect(try sealer.open(try sealer.seal(secret)) == secret)
        #expect(factory.calls == 2)
    }

    static let unavailableForTheSession: [SecretSealingError] = [
        .keyUnavailable(.missingEntitlement), .keyUnavailable(.unexpectedStatus(-25_293)),
        .keyUnavailable(.unexpectedItemData), .invalidKeyLength(16),
    ]

    @Test(arguments: unavailableForTheSession)
    func otherKeyFailuresWaitForTheNextLaunch(_ failure: SecretSealingError) async {
        let factory = SealerFactorySpy(failure: failure)
        let sealer = factory.makeLazySealer()

        #expect(await sealer.loadKey() == .unavailable)
        #expect(await sealer.loadKey() == .unavailable)
        #expect(factory.calls == 1)
    }

    @Test func concurrentLoadsCreateTheSealerOnce() async throws {
        let factory = SealerFactorySpy()
        let sealer = factory.makeLazySealer()

        let states = await withTaskGroup(of: SealingKeyState.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    await sealer.loadKey()
                }
            }
            var results: [SealingKeyState] = []
            for await state in group {
                results.append(state)
            }
            return results
        }

        #expect(states == Array(repeating: .ready, count: 64))
        #expect(factory.calls == 1)
    }

    @Test func aSealerThatNeedsNoKeyIsAlwaysReady() async {
        #expect(await FakeSecretSealer().loadKey() == .ready)
    }
}
