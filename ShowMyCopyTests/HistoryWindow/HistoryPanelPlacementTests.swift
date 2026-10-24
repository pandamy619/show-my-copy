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

struct HistoryPanelResizeTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func fullSizeIsTheListSize() {
        #expect(HistoryPanelPlacement.fullSize == CGSize(width: 480, height: 420))
        #expect(HistoryPanelPlacement.size(showsEntries: true) == HistoryPanelPlacement.fullSize)
    }

    @Test func compactSizeFitsTheSearchBarAndOneMessageRow() {
        let compact = HistoryPanelPlacement.size(showsEntries: false)
        #expect(compact.width == 480)
        #expect(compact.height == HistoryPanelPlacement.compactHeight)
        let rows =
            HistoryPanelPlacement.searchBarHeight + HistoryPanelPlacement.dividerHeight
            + HistoryPanelPlacement.messageRowHeight
        #expect(HistoryPanelPlacement.compactHeight == rows)
        #expect(compact.height < HistoryPanelPlacement.fullSize.height)
    }

    @Test func growingKeepsTheTopAndLeftEdges() {
        let compact = CGRect(x: 480, y: 623, width: 480, height: 97)
        let grown = HistoryPanelPlacement.frame(
            resizing: compact, to: HistoryPanelPlacement.fullSize, in: screen)
        #expect(grown == CGRect(x: 480, y: 300, width: 480, height: 420))
        #expect(grown.maxY == compact.maxY)
    }

    @Test func shrinkingKeepsTheTopAndLeftEdges() {
        let full = CGRect(x: 480, y: 300, width: 480, height: 420)
        let compact = HistoryPanelPlacement.frame(
            resizing: full, to: HistoryPanelPlacement.size(showsEntries: false), in: screen)
        #expect(compact.maxY == full.maxY)
        #expect(compact.minX == full.minX)
        #expect(compact.height == HistoryPanelPlacement.compactHeight)
    }

    @Test func growingNearTheBottomOfTheScreenStaysOnScreen() {
        // The user dragged the compact panel close to the Dock.
        let compact = CGRect(x: 100, y: 50, width: 480, height: 97)
        let grown = HistoryPanelPlacement.frame(
            resizing: compact, to: HistoryPanelPlacement.fullSize, in: screen)
        #expect(grown == CGRect(x: 100, y: 0, width: 480, height: 420))
    }

    @Test func growingOnAScreenShorterThanThePanelKeepsTheTopOnScreen() {
        let short = CGRect(x: 0, y: 0, width: 800, height: 300)
        let compact = CGRect(x: 0, y: 200, width: 480, height: 97)
        let grown = HistoryPanelPlacement.frame(
            resizing: compact, to: HistoryPanelPlacement.fullSize, in: short)
        // The search field must stay reachable, so the top edge wins over the bottom one.
        #expect(grown.maxY == short.maxY)
    }

    @Test func withoutAScreenOnlyTheTopEdgeIsKept() {
        let compact = CGRect(x: 0, y: 0, width: 480, height: 97)
        let grown = HistoryPanelPlacement.frame(resizing: compact, to: HistoryPanelPlacement.fullSize, in: nil)
        #expect(grown == CGRect(x: 0, y: -323, width: 480, height: 420))
    }

    @Test func compactPanelOpensWhereTheFullPanelsTopWouldBe() {
        let compact = HistoryPanelPlacement.size(showsEntries: false)
        let origin = HistoryPanelPlacement.origin(for: compact, in: screen)
        let fullOrigin = HistoryPanelPlacement.origin(for: HistoryPanelPlacement.fullSize, in: screen)
        #expect(origin.y + compact.height == fullOrigin.y + HistoryPanelPlacement.fullSize.height)
    }
}
