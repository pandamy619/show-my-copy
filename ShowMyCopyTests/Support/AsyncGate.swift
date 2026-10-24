import Foundation
import Synchronization

/// Holds background work at one point until the test lets it go on, so a test can change the history while the work
/// is in flight. The work suspends there: no thread is blocked, which on Linux would also stall the main actor, and
/// no real time passes.
final class AsyncGate: Sendable {
    private struct State {
        var isArmed = false
        var hasArrived = false
        /// The work held at the gate.
        var held: CheckedContinuation<Void, Never>?
        /// The test waiting for the work to arrive.
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    /// The next work that passes the gate stops there.
    func arm() {
        state.withLock { state in
            state.isArmed = true
            state.hasArrived = false
        }
    }

    /// Called by fakes in the work: suspends there when the gate is armed, once, until `open()`.
    func pass() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let arrival: (stops: Bool, waiter: CheckedContinuation<Void, Never>?) = state.withLock { state in
                guard state.isArmed else {
                    return (false, nil)
                }
                state.isArmed = false
                state.hasArrived = true
                state.held = continuation
                defer { state.waiter = nil }
                return (true, state.waiter)
            }
            if arrival.stops {
                arrival.waiter?.resume()
            } else {
                continuation.resume()
            }
        }
    }

    /// Waits until the work stopped at the gate.
    @MainActor
    func waitUntilReached() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let hasArrived = state.withLock { state in
                guard state.hasArrived else {
                    state.waiter = continuation
                    return false
                }
                return true
            }
            if hasArrived {
                continuation.resume()
            }
        }
    }

    /// Lets the held work go on, or disarms the gate when nothing arrived yet.
    func open() {
        let held = state.withLock { state in
            state.isArmed = false
            defer { state.held = nil }
            return state.held
        }
        held?.resume()
    }
}
