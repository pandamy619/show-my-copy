import Foundation
import Synchronization

/// Runs work that may block for a long time, such as reading a file's metadata on a disk that has to spin up, with a
/// time limit that holds even when the work cannot be stopped.
///
/// A task group would not do: it waits for every child, and a synchronous call inside one (`stat`, `resourceValues`)
/// ignores cancellation, so one stuck file would hold the caller for as long as it is stuck. Here the work runs in a
/// task of its own; when the time is up the caller goes on, the work is cancelled, and whatever it returns later is
/// dropped. It must therefore not change anything the caller relies on after the limit, except through what it
/// returns.
enum TimeLimit {
    /// The value of `work`, or nil when `limit` passed first or the calling task was cancelled.
    static func run<Value: Sendable>(
        within limit: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        _ work: @escaping @Sendable () async -> Value
    ) async -> Value? {
        let first = FirstResult<Value?>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
                first.start(continuation)
                let worker = Task.detached {
                    first.finish(await work())
                }
                let timer = Task.detached {
                    do {
                        try await sleep(limit)
                    } catch {
                        // Cancelled: the work finished first, or the caller was cancelled.
                    }
                    first.finish(nil)
                }
                first.onFinish {
                    worker.cancel()
                    timer.cancel()
                }
            }
        } onCancel: {
            first.finish(nil)
        }
    }
}

/// Resumes the caller with the first result that arrives, once, and then runs the clean-up.
private final class FirstResult<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, Never>?
        var result: Value?
        var isFinished = false
        var cleanUp: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())

    func start(_ continuation: CheckedContinuation<Value, Never>) {
        let early: Value? = state.withLock { state in
            guard state.isFinished else {
                state.continuation = continuation
                return nil
            }
            return state.result
        }
        if let early {
            continuation.resume(returning: early)
        }
    }

    func onFinish(_ cleanUp: @escaping @Sendable () -> Void) {
        let runNow = state.withLock { state in
            guard state.isFinished else {
                state.cleanUp = cleanUp
                return false
            }
            return true
        }
        if runNow {
            cleanUp()
        }
    }

    func finish(_ value: Value) {
        let finished: (CheckedContinuation<Value, Never>?, (@Sendable () -> Void)?)? = state.withLock { state in
            guard !state.isFinished else {
                return nil
            }
            state.isFinished = true
            state.result = value
            defer {
                state.continuation = nil
                state.cleanUp = nil
            }
            return (state.continuation, state.cleanUp)
        }
        guard let finished else {
            return
        }
        finished.0?.resume(returning: value)
        finished.1?()
    }
}
