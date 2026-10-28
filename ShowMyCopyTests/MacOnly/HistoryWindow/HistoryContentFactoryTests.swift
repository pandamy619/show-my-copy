import AppKit
import SwiftUI
import Testing

@testable import ShowMyCopy

@MainActor
struct HistoryContentFactoryTests {
    @Test func contentIgnoresTheTitleBarSafeArea() throws {
        // The hidden title bar would otherwise push the search field down by its height.
        let view = HistoryContentFactory.makeView(
            model: HistoryWindowModel(history: InMemoryHistoryStore()),
            onChoose: { _ in },
            onClose: {},
            onOpenSettings: {}
        )
        let hostingView = try #require(view as? NSHostingView<HistoryView>)
        #expect(hostingView.safeAreaRegions.isEmpty)
        #expect(hostingView.sizingOptions.isEmpty)
    }
}
