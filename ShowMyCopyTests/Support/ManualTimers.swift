import Foundation
import Synchronization

/// Replaces `Task.sleep` for code that races work against a time limit off the main actor. A sleep ends only when
/// the test fires it, or throws `CancellationError` when its task is cancelled, like `Task.sleep`. No real time
/// passes, so a test never depends on how fast the machine runs.
final class ManualTimers: Sendable {
    private struct Sleeper {
        let duration: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct Waiter {
        let duration: Duration
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var nextID = 0
        var sleepers: [Int: Sleeper] = [:]
        /// Sleeps cancelled before they were registered.
        var cancelled: Set<Int> = []
        var waiters: [Waiter] = []
        var requested: [Duration] = []
    }

    private let state = Mutex(State())

    /// Every duration slept for, in order.
    var requestedDurations: [Duration] {
        state.withLock { $0.requested }
    }

    /// Pass this where the code takes a `sleep` closure.
    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] duration in try await self.sleep(for: duration) }
    }

    func sleep(for duration: Duration) async throws {
        let id = state.withLock { state in
            state.requested.append(duration)
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let woken: [Waiter]? = state.withLock { state in
                    if state.cancelled.remove(id) != nil {
                        return nil
                    }
                    state.sleepers[id] = Sleeper(duration: duration, continuation: continuation)
                    let woken = state.waiters.filter { $0.duration == duration }
                    state.waiters.removeAll { $0.duration == duration }
                    return woken
                }
                guard let woken else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                for waiter in woken {
                    waiter.continuation.resume()
                }
            }
        } onCancel: {
            let sleeper = state.withLock { state in
                guard let sleeper = state.sleepers.removeValue(forKey: id) else {
                    state.cancelled.insert(id)
                    return Sleeper?.none
                }
                return sleeper
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Waits, without real time passing, until something sleeps for `duration`.
    func waitForSleep(of duration: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isSleeping = state.withLock { state in
                guard !state.sleepers.values.contains(where: { $0.duration == duration }) else {
                    return true
                }
                state.waiters.append(Waiter(duration: duration, continuation: continuation))
                return false
            }
            if isSleeping {
                continuation.resume()
            }
        }
    }

    /// Ends every sleep of `duration` going on now, as if that much time had passed.
    func fire(_ duration: Duration) {
        let fired = state.withLock { state in
            let ids = state.sleepers.filter { $0.value.duration == duration }.map(\.key)
            return ids.compactMap { state.sleepers.removeValue(forKey: $0) }
        }
        for sleeper in fired {
            sleeper.continuation.resume()
        }
    }
}

/// Suspends until the calling task is cancelled, for fakes of work that never finishes on its own.
func suspendUntilCancelled() async {
    let (stream, continuation) = AsyncStream<Never>.makeStream()
    // Nothing ever finishes the stream, so iterating ends only when the task is cancelled.
    for await _ in stream {}
    withExtendedLifetime(continuation) {}
}
