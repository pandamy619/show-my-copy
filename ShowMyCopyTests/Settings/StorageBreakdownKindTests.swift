import Foundation
import Testing

@testable import ShowMyCopy

@MainActor
struct StorageBreakdownKindTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func everyKindHasItsOwnPartInOrder() {
        let history = InMemoryHistoryStore()
        history.record(ContentFixtures.files("/Users/me/a.txt"), sourceApp: nil, at: start)
        history.record(ContentFixtures.image(byteSize: 1000, thumbnailBytes: 100), sourceApp: nil, at: start + 1)
        history.record(.richText(rtf: Data(count: 50), plain: "plain"), sourceApp: nil, at: start + 2)
        history.record(text: "hello", sourceApp: nil, at: start + 3)
        history.record(text: "secret", sourceApp: nil, at: start + 4, concealed: true, expiresAt: start + 60)

        let breakdown = StorageBreakdown(entries: history.entries)

        #expect(
            breakdown.parts == [
                StorageBreakdown.Part(category: .text, count: 1, bytes: 5),
                StorageBreakdown.Part(category: .richText, count: 1, bytes: 55),
                StorageBreakdown.Part(category: .images, count: 1, bytes: 1100),
                StorageBreakdown.Part(category: .files, count: 1, bytes: "/Users/me/a.txt".utf8.count + 5),
                StorageBreakdown.Part(category: .passwords, count: 1, bytes: 6),
            ])
        #expect(breakdown.totalBytes == history.stats().totalBytes)
    }

    @Test func concealedRichTextCountsAsAPassword() {
        let history = InMemoryHistoryStore()
        history.record(
            .richText(rtf: Data(count: 10), plain: "pw"), sourceApp: nil, at: start, concealed: true,
            expiresAt: start + 60)
        #expect(StorageBreakdown(entries: history.entries).parts.map(\.category) == [.passwords])
    }
}
