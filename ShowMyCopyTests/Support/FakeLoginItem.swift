import Synchronization

@testable import ShowMyCopy

/// Stands in for `SMAppService.mainApp`: keeps a status that tests set, as the user would in System Settings, and
/// moves it the way macOS does when the app registers or unregisters. It starts as a fresh install: not registered.
final class FakeLoginItem: LoginItemService {
    private struct State {
        var status: LoginItemStatus = .notRegistered
        /// The status a successful register leaves.
        var statusAfterRegister: LoginItemStatus = .enabled
        var registerFails = false
        var unregisterFails = false
        var statusReads = 0
        var registerCount = 0
        var unregisterCount = 0
        var openSystemSettingsCount = 0
    }

    private let state = Mutex(State())
    /// Holds the next status read, when armed.
    let statusGate = AsyncGate()
    /// Holds the next register or unregister, when armed.
    let changeGate = AsyncGate()

    init(status: LoginItemStatus = .notRegistered) {
        state.withLock { $0.status = status }
    }

    /// What the system reports now; tests change it as the user would in System Settings.
    var currentStatus: LoginItemStatus {
        get { state.withLock { $0.status } }
        set { state.withLock { $0.status = newValue } }
    }

    var statusAfterRegister: LoginItemStatus {
        get { state.withLock { $0.statusAfterRegister } }
        set { state.withLock { $0.statusAfterRegister = newValue } }
    }

    /// When true, register throws and leaves the status as it is.
    var registerFails: Bool {
        get { state.withLock { $0.registerFails } }
        set { state.withLock { $0.registerFails = newValue } }
    }

    /// When true, unregister throws and leaves the status as it is.
    var unregisterFails: Bool {
        get { state.withLock { $0.unregisterFails } }
        set { state.withLock { $0.unregisterFails = newValue } }
    }

    var statusReads: Int { state.withLock { $0.statusReads } }
    var registerCount: Int { state.withLock { $0.registerCount } }
    var unregisterCount: Int { state.withLock { $0.unregisterCount } }
    var openSystemSettingsCount: Int { state.withLock { $0.openSystemSettingsCount } }

    func status() async -> LoginItemStatus {
        // Read before the gate: a read held there returns what the system said when it was asked.
        let status = state.withLock { state in
            state.statusReads += 1
            return state.status
        }
        await statusGate.pass()
        return status
    }

    func register() async throws(LoginItemError) {
        await changeGate.pass()
        let fails = state.withLock { state in
            state.registerCount += 1
            if !state.registerFails {
                state.status = state.statusAfterRegister
            }
            return state.registerFails
        }
        if fails {
            throw .failed
        }
    }

    func unregister() async throws(LoginItemError) {
        await changeGate.pass()
        let fails = state.withLock { state in
            state.unregisterCount += 1
            if !state.unregisterFails {
                state.status = .notRegistered
            }
            return state.unregisterFails
        }
        if fails {
            throw .failed
        }
    }

    @MainActor
    func openSystemSettings() {
        state.withLock { $0.openSystemSettingsCount += 1 }
    }
}
