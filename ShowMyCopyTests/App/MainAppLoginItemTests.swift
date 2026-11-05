import ServiceManagement
import Testing

@testable import ShowMyCopy

/// Only the status is checked: registering in a test would change the login items of the Mac running it.
struct MainAppLoginItemTests {
    @Test(arguments: [
        (SMAppService.Status.notRegistered, LoginItemStatus.notRegistered),
        (.enabled, .enabled),
        (.requiresApproval, .requiresApproval),
        (.notFound, .notFound),
    ])
    func mapsEveryStatusOfTheSystem(system: SMAppService.Status, expected: LoginItemStatus) {
        #expect(MainAppLoginItem.status(of: system) == expected)
    }

    @Test func readsTheStatusOfTheRunningApp() async {
        // The test host is the app. Reading the status changes nothing; any of the cases is fine.
        let status = await MainAppLoginItem().status()
        let known: [LoginItemStatus] = [.notRegistered, .enabled, .requiresApproval, .notFound]
        #expect(known.contains(status))
    }
}
