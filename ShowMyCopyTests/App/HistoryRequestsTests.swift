import Testing

@testable import ShowMyCopy

/// Stands in for the container and counts how often it was asked to show the history.
@MainActor
final class HistoryShowingSpy: HistoryShowing {
    private(set) var showCount = 0

    func showHistory() {
        showCount += 1
    }
}

@MainActor
struct HistoryRequestsTests {
    @Test func requestShowsTheHistory() {
        let requests = HistoryRequests()
        let app = HistoryShowingSpy()
        requests.connect(app)

        requests.showHistory()
        requests.showHistory()

        #expect(app.showCount == 2)
    }

    /// The Control Center button can launch the app; the history is still loading when the request arrives.
    @Test func requestBeforeTheAppIsReadyShowsTheHistoryOnceItIs() {
        let requests = HistoryRequests()
        let app = HistoryShowingSpy()

        requests.showHistory()
        requests.showHistory()
        #expect(app.showCount == 0)

        requests.connect(app)
        // Pressed twice while loading: the window opens once.
        #expect(app.showCount == 1)

        requests.showHistory()
        #expect(app.showCount == 2)
    }

    @Test func connectingWithoutARequestShowsNothing() {
        let requests = HistoryRequests()
        let app = HistoryShowingSpy()

        requests.connect(app)

        #expect(app.showCount == 0)
    }

    @Test func aRequestIsDeliveredOnlyOnce() {
        let requests = HistoryRequests()
        let first = HistoryShowingSpy()
        let second = HistoryShowingSpy()
        requests.showHistory()

        requests.connect(first)
        requests.connect(second)

        #expect(first.showCount == 1)
        #expect(second.showCount == 0)
    }

    /// App Intents keeps the registered requests for as long as the app runs; they must not keep the container alive.
    @Test func requestsDoNotKeepTheAppAlive() {
        let requests = HistoryRequests()
        weak var released: HistoryShowingSpy?
        do {
            let app = HistoryShowingSpy()
            requests.connect(app)
            released = app
        }

        #expect(released == nil)
    }
}
