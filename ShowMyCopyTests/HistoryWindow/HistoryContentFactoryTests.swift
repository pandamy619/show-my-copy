import AppKit
import SwiftUI
import Testing

@testable import ShowMyCopy

@MainActor
struct HistoryContentFactoryTests {
    @Test func contentIgnoresTheTitleBarSafeArea() throws {
        // The hidden title bar would otherwise push the search field down by its height.
        let actions = HistoryViewActions(
            choose: { _, _ in }, close: {}, openSettings: {}, drag: { _ in }, copyText: { _ in })
        let view = HistoryContentFactory.makeView(
            model: HistoryWindowModel(history: InMemoryHistoryStore()), actions: actions)
        let hostingView = try #require(view as? NSHostingView<HistoryView>)
        #expect(hostingView.safeAreaRegions.isEmpty)
        #expect(hostingView.sizingOptions.isEmpty)
    }
}
