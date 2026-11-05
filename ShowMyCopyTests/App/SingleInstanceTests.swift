import Testing

@testable import ShowMyCopy

struct SingleInstanceTests {
    private let app = "dev.example.ShowMyCopy"

    private func running(
        _ bundleIdentifier: String?, _ pid: Int32, terminated: Bool = false
    ) -> SingleInstance.RunningCopy {
        SingleInstance.RunningCopy(bundleIdentifier: bundleIdentifier, processIdentifier: pid, isTerminated: terminated)
    }

    @Test func anotherProcessOfTheAppIsFound() {
        #expect(SingleInstance.anotherIsRunning(bundleIdentifier: app, ownProcess: 2, running: [running(app, 1)]))
    }

    @Test func theAppAloneIsNotAnother() {
        #expect(!SingleInstance.anotherIsRunning(bundleIdentifier: app, ownProcess: 2, running: [running(app, 2)]))
    }

    @Test func otherAppsAndQuitProcessesDoNotCount() {
        let apps = [running("com.apple.TextEdit", 1), running(app, 3, terminated: true), running(nil, 4)]
        #expect(!SingleInstance.anotherIsRunning(bundleIdentifier: app, ownProcess: 2, running: apps))
    }

    @Test func withoutABundleIdentifierNothingIsTheSameApp() {
        #expect(!SingleInstance.anotherIsRunning(bundleIdentifier: nil, ownProcess: 2, running: [running(nil, 1)]))
        #expect(!SingleInstance.anotherIsRunning(bundleIdentifier: "", ownProcess: 2, running: [running("", 1)]))
    }
}
