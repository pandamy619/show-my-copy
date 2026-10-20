import Foundation
import Testing

@testable import ShowMyCopy

struct HistoryPanelPlacementTests {
    private let size = CGSize(width: 480, height: 420)

    @Test func centersHorizontallyInUpperPartOfScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = HistoryPanelPlacement.origin(for: size, in: screen)
        // 20% of 900 below the top edge: 900 - 180 - 420.
        #expect(origin == CGPoint(x: 480, y: 300))
    }

    @Test func usesTheGivenScreenOffset() {
        let screen = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
        let origin = HistoryPanelPlacement.origin(for: size, in: screen)
        // x: -1920 + (1920 - 480) / 2, y: 200 + 1080 - 216 - 420.
        #expect(origin == CGPoint(x: -1200, y: 644))
    }

    @Test func staysOnShortScreen() {
        let screen = CGRect(x: 0, y: 0, width: 400, height: 450)
        let origin = HistoryPanelPlacement.origin(for: size, in: screen)
        #expect(origin.x == 0)
        #expect(origin.y >= 0)
        #expect(origin.y + size.height <= 450)
    }
}
