import Testing

/// Runs the tests of every suite that carries it one at a time, across suites.
///
/// `.serialized` only orders the tests inside one suite, and Swift Testing runs different suites at the same time.
/// A test that opens the history window or Settings takes the key window, and the history window closes when it
/// stops being key. So a test waiting with its panel open, for a resize say, lost its panel whenever a test of
/// another suite opened a window meanwhile. Every suite that opens a window waits its turn here.
struct OneWindowAtATime: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        // Called for the suite as well as for each of its tests. Hold the turn per test only.
        guard testCase != nil else {
            try await function()
            return
        }
        await WindowTurn.shared.take()
        do {
            try await function()
        } catch {
            await WindowTurn.shared.giveBack()
            throw error
        }
        await WindowTurn.shared.giveBack()
    }
}

extension Trait where Self == OneWindowAtATime {
    /// See `OneWindowAtATime`.
    static var oneWindowAtATime: Self { OneWindowAtATime() }
}

/// One turn, handed to the waiting tests in the order they asked. Waiting suspends, it blocks no thread.
private actor WindowTurn {
    static let shared = WindowTurn()

    private var isTaken = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func take() async {
        guard isTaken else {
            isTaken = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func giveBack() {
        guard !waiting.isEmpty else {
            isTaken = false
            return
        }
        // The turn passes straight on, so `isTaken` stays true.
        waiting.removeFirst().resume()
    }
}
