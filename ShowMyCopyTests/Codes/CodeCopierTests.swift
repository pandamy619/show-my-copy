import Foundation
import Testing

@testable import ShowMyCopy

@MainActor
struct CodeCopierTests {
    private let pasteboard = FakePasteboard()
    private let history = InMemoryHistoryStore()
    private let timers = ManualTimers()
    private let clock = ManualDate(Date(timeIntervalSince1970: 59))
    private let account = CodeFixtures.stored()
    private let finder = SourceApp(bundleIdentifier: "com.apple.finder", name: "Finder")

    private func makeCopier() -> (CodeCopier, ClipboardMonitor) {
        let monitor = MonitorFactory.make(
            pasteboard: pasteboard, history: history, frontmostApp: { [finder] in finder })
        monitor.poll()
        let copier = CodeCopier(
            history: history, pasteboard: pasteboard, monitor: monitor, now: clock.read, sleep: timers.sleep)
        return (copier, monitor)
    }

    @Test func writesTheCodeOfNowConcealedAndUnrecorded() {
        let (copier, _) = makeCopier()

        let changeCount = copier.copy(account)

        #expect(changeCount == pasteboard.changeCount)
        #expect(pasteboard.writtenTexts == ["996554"])
        #expect(pasteboard.writtenConcealed == [true])
        #expect(pasteboard.writtenUnrecordedTexts == ["996554"])
    }

    @Test func theCodeIsNeverRecordedAndNoEntryIsCurrent() {
        history.record(text: "older", sourceApp: finder, at: Date(timeIntervalSince1970: 1))
        let (copier, monitor) = makeCopier()
        pasteboard.copy("older")
        monitor.poll()
        #expect(history.currentEntryID != nil)

        copier.copy(account)
        monitor.poll()

        #expect(history.entries.map(\.text) == ["older"])
        #expect(history.currentEntryID == nil)
    }

    @Test func theClipboardIsEmptiedAfterOnePeriodWhenItStillHoldsTheCode() async throws {
        let (copier, monitor) = makeCopier()
        let changeCount = try #require(copier.copy(account))

        await timers.waitForSleep(of: .seconds(30))
        timers.fire(.seconds(30))
        await copier.pendingClear?.value

        #expect(pasteboard.clearedChangeCounts == [changeCount])
        #expect(pasteboard.text == nil)
        // The app's own change: not a copy, not a password manager clearing a password.
        #expect(monitor.handledChangeCount == pasteboard.changeCount)
        monitor.poll()
        #expect(history.entries.isEmpty)
    }

    @Test func theClipboardIsLeftAloneWhenSomethingWasCopiedSince() async throws {
        let (copier, _) = makeCopier()
        copier.copy(account)
        await timers.waitForSleep(of: .seconds(30))
        pasteboard.copy("something else")

        timers.fire(.seconds(30))
        await copier.pendingClear?.value

        #expect(pasteboard.clearedChangeCounts.isEmpty)
        #expect(pasteboard.text == "something else")
    }

    @Test func aNewerCopyReplacesTheClearingOfTheOlderOne() async throws {
        let (copier, _) = makeCopier()
        copier.copy(account)
        await timers.waitForSleep(of: .seconds(30))
        let first = copier.pendingClear
        let second = try #require(copier.copy(account))
        await first?.value

        #expect(pasteboard.clearedChangeCounts.isEmpty)
        await timers.waitForSleep(of: .seconds(30))
        timers.fire(.seconds(30))
        await copier.pendingClear?.value
        #expect(pasteboard.clearedChangeCounts == [second])
    }

    @Test func quittingEmptiesTheClipboardWhenItStillHoldsTheCode() async throws {
        let (copier, monitor) = makeCopier()
        let changeCount = try #require(copier.copy(account))
        await timers.waitForSleep(of: .seconds(30))

        copier.clearCopiedCode()
        await copier.pendingClear?.value

        #expect(pasteboard.clearedChangeCounts == [changeCount])
        #expect(pasteboard.text == nil)
        #expect(monitor.handledChangeCount == pasteboard.changeCount)
        #expect(copier.pendingClear == nil)
        // Done once: the scheduled clearing was cancelled and a second call finds nothing to clear.
        copier.clearCopiedCode()
        #expect(pasteboard.clearedChangeCounts == [changeCount])
    }

    @Test func quittingLeavesTheClipboardAloneWhenSomethingWasCopiedSince() async throws {
        let (copier, _) = makeCopier()
        copier.copy(account)
        await timers.waitForSleep(of: .seconds(30))
        pasteboard.copy("something else")

        copier.clearCopiedCode()

        #expect(pasteboard.clearedChangeCounts.isEmpty)
        #expect(pasteboard.text == "something else")
        #expect(copier.pendingClear == nil)
    }

    @Test func quittingWithoutACopiedCodeDoesNothing() {
        let (copier, _) = makeCopier()
        pasteboard.copy("text")

        copier.clearCopiedCode()

        #expect(pasteboard.clearedChangeCounts.isEmpty)
        #expect(pasteboard.text == "text")
    }

    @Test func aFailedWriteChangesNothing() {
        pasteboard.writeFails = true
        let (copier, _) = makeCopier()

        #expect(copier.copy(account) == nil)
        #expect(copier.pendingClear == nil)
    }
}
