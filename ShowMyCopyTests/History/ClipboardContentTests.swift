import Foundation
import Testing

@testable import ShowMyCopy

struct ClipboardContentTests {
    private let composed = "caf\u{E9}"
    private let decomposed = "cafe\u{301}"

    @Test func textContentDescribesItself() {
        let content = ClipboardContent.text("h\u{E9}llo")
        #expect(content.kind == .text)
        #expect(content.text == "h\u{E9}llo")
        #expect(content.byteSize == 6)
    }

    @Test func canonicalBytesStartWithTheKindTag() {
        #expect(ClipboardContent.text("abc").canonicalBytes == Data([0x01, 0x61, 0x62, 0x63]))
    }

    @Test func canonicallyEqualTextsHaveTheSameBytes() {
        #expect(composed == decomposed)
        #expect(ClipboardContent.text(composed).canonicalBytes == ClipboardContent.text(decomposed).canonicalBytes)
    }

    @Test func sha256HasherMatchesTheStandardTestVector() {
        let digest = SHA256ContentHasher().digest(of: Data("abc".utf8))
        #expect(digest.description == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func contentHashIsTheDigestOfTheCanonicalBytes() {
        // SHA-256 of 0x01 followed by "é" in NFC. Hashes are saved with the history, so this value must never change.
        let expected = "c9acd1a507da6bc057b2d6a5e5e029d06bca4f4787c977c95510c1900d046da0"
        #expect(SHA256ContentHasher().hash(.text("\u{E9}")).description == expected)
        #expect(SHA256ContentHasher().hash(.text("e\u{301}")).description == expected)
    }

    @Test func differentTextsHaveDifferentHashes() {
        let hasher = SHA256ContentHasher()
        #expect(hasher.hash(.text("a")) != hasher.hash(.text("b")))
        #expect(hasher.hash(.text("a")) != hasher.hash(.text("a ")))
    }

    @Test func entryDerivesItsMetadataFromTheContent() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let entry = ClipboardEntry(text: "  first line\n\n\u{202E}second  line", date: date, sourceApp: nil)
        #expect(entry.kind == .text)
        #expect(entry.text == "  first line\n\n\u{202E}second  line")
        #expect(entry.byteSize == 29)
        #expect(entry.previewText == "first line\nsecond line")
        #expect(entry.contentHash == SHA256ContentHasher().hash(entry.content))
        #expect(!entry.isPinned)
        #expect(!entry.isConcealed)
    }
}

/// Gives every content the same hash, to show that the history compares hashes, not text.
private struct ConstantHasher: ContentHasher {
    func digest(of data: Data) -> ContentHash {
        ContentHash(bytes: [0])
    }
}

@MainActor
struct InMemoryHistoryStoreContentHashTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func canonicallyEqualTextIsOneEntry() {
        let history = InMemoryHistoryStore()
        let id = history.record(text: "caf\u{E9}", sourceApp: nil, at: start)
        #expect(history.record(text: "cafe\u{301}", sourceApp: nil, at: start + 1) == id)
        #expect(history.entries.count == 1)
    }

    @Test func entriesWithTheSameHashAreOneEntry() {
        let history = InMemoryHistoryStore(hasher: ConstantHasher())
        let id = history.record(text: "first", sourceApp: nil, at: start)
        #expect(history.record(text: "second", sourceApp: nil, at: start + 1) == id)
        #expect(history.entries.map(\.text) == ["first"])
        #expect(history.entries.first?.date == start + 1)
    }
}
