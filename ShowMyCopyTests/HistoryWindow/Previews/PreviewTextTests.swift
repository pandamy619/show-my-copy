import Foundation
import Testing

@testable import ShowMyCopy

struct PreviewTextTests {
    @Test func keepsLineBreaksAndTabs() {
        #expect(PreviewText.sanitized("one\n\ttwo\r\nthree") == "one\n\ttwo\r\nthree")
    }

    @Test func removesControlDirectionAndAttachmentCharacters() {
        let text = "a\u{202E}b\u{0007}c\u{FFFC}d\u{2066}e\u{200F}"
        #expect(PreviewText.sanitized(text) == "abcde")
    }

    @Test func cutsLongTextWithAnEllipsis() {
        #expect(PreviewText.sanitized("abcdef", maximumCharacters: 4) == "abcd…")
        #expect(PreviewText.sanitized("abcd", maximumCharacters: 4) == "abcd")
        // Removed characters after the limit do not count as more text.
        #expect(PreviewText.sanitized("abcd\u{202E}", maximumCharacters: 4) == "abcd")
    }

    @Test func countsCharactersNotScalars() {
        let family = "👨‍👩‍👧"
        #expect(PreviewText.sanitized(family + family, maximumCharacters: 1) == family + "…")
        #expect(PreviewText.sanitized("e\u{301}x", maximumCharacters: 1) == "e\u{301}…")
    }

    @Test func removedRangesAreUTF16OffsetsMergedWhenAdjacent() {
        #expect(PreviewText.removedRanges(in: "plain") == [])
        #expect(PreviewText.removedRanges(in: "a\u{FFFC}b") == [1..<2])
        #expect(PreviewText.removedRanges(in: "a\u{202E}\u{202C}b\u{FFFC}") == [1..<3, 4..<5])
        // An emoji takes two UTF-16 units before the removed character.
        #expect(PreviewText.removedRanges(in: "😀\u{FFFC}") == [2..<3])
    }

    @Test func truncationOffsetIsBetweenCharacters() {
        #expect(PreviewText.truncationOffset(in: "abc", maximumCharacters: 3) == nil)
        #expect(PreviewText.truncationOffset(in: "abcd", maximumCharacters: 3) == 3)
        #expect(PreviewText.truncationOffset(in: "😀😀", maximumCharacters: 1) == 2)
        #expect(PreviewText.truncationOffset(in: "", maximumCharacters: 0) == nil)
    }

    @Test func fontSizesAreClamped() {
        #expect(RichTextPreviewPolicy.clampedFontSize(1) == 8)
        #expect(RichTextPreviewPolicy.clampedFontSize(13) == 13)
        #expect(RichTextPreviewPolicy.clampedFontSize(500) == 48)
        #expect(RichTextPreviewPolicy.clampedFontSize(.nan) == 8)
        #expect(RichTextPreviewPolicy.clampedFontSize(.infinity) == 8)
    }
}
