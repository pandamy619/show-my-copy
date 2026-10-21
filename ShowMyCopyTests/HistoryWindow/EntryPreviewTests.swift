import Foundation
import Testing

@testable import ShowMyCopy

struct EntryPreviewTests {
    private let english = Locale(identifier: "en_US")

    @Test func shortTextIsUnchanged() {
        #expect(EntryPreview.text("hello world") == "hello world")
    }

    @Test(arguments: [
        ("a\u{202E}b\u{202A}c\u{202B}d\u{202C}e\u{202D}f", "abcdef"),
        ("a\u{2066}b\u{2067}c\u{2068}d\u{2069}e", "abcde"),
        ("a\u{200E}b\u{200F}c\u{061C}d", "abcd"),
    ])
    func removesBidiFormattingCharacters(text: String, expected: String) {
        #expect(EntryPreview.text(text) == expected)
    }

    @Test func removesControlCharacters() {
        #expect(EntryPreview.text("a\u{0}b\u{7}c\u{1B}[31md\u{7F}e\u{9B}f") == "abc[31mdef")
    }

    @Test func collapsesWhitespaceAndTabs() {
        #expect(EntryPreview.text("  \t one \t\t two   ") == "one two")
    }

    @Test func keepsFirstTwoNonBlankLines() {
        #expect(EntryPreview.text("\n\n  first  \r\n\n\tsecond\nthird") == "first\nsecond…")
        #expect(EntryPreview.text("first\u{2028}second") == "first\nsecond")
        #expect(EntryPreview.text("first\nsecond\n\n  \n") == "first\nsecond")
    }

    @Test func blankTextGivesEmptyPreview() {
        #expect(EntryPreview.text(" \n\t\u{202E}\u{0}\r\n ").isEmpty)
    }

    @Test func longTextIsCutToMaximumCharacters() {
        let preview = EntryPreview.text(String(repeating: "a", count: 1_048_576))
        #expect(preview == String(repeating: "a", count: EntryPreview.maximumCharacters) + EntryPreview.ellipsis)
    }

    @Test func limitCoversBothLines() {
        let line = String(repeating: "b", count: 200)
        let preview = EntryPreview.text(line + "\n" + line)
        let lines = preview.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].count == 200)
        #expect(lines[1] == String(repeating: "b", count: 100) + EntryPreview.ellipsis)
    }

    @Test func longLineOfCombiningMarksIsBounded() {
        let zalgo = "a" + String(repeating: "\u{0301}", count: 100_000)
        #expect(EntryPreview.text(zalgo).unicodeScalars.count <= EntryPreview.maximumCharacters * 4 + 1)
    }

    @Test func emojiSequencesStayIntact() {
        #expect(EntryPreview.text("👩‍💻 done") == "👩‍💻 done")
    }

    @Test func recentDateIsNow() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(EntryPreview.relativeTime(of: now - 30, now: now, locale: english) == "now")
        // A clock that moved backwards must not show a time in the future.
        #expect(EntryPreview.relativeTime(of: now + 600, now: now, locale: english) == "now")
    }

    @Test func olderDateShowsElapsedTime() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let minutes = EntryPreview.relativeTime(of: now - 5 * 60, now: now, locale: english)
        #expect(minutes.contains("5"))
        #expect(minutes.hasSuffix("ago"))
        let days = EntryPreview.relativeTime(of: now - 3 * 86_400, now: now, locale: english)
        #expect(days.contains("3"))
    }
}

struct ConcealedEntryPreviewTests {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    private func entry(_ text: String, concealed: Bool) -> ClipboardEntry {
        ClipboardEntry(
            id: UUID(), text: text, date: date, sourceApp: nil, isConcealed: concealed,
            expiresAt: concealed ? date + 600 : nil)
    }

    @Test(arguments: ["a", "hunter2", String(repeating: "x", count: 500)])
    func maskDoesNotDependOnThePassword(password: String) {
        #expect(EntryPreview.rowText(for: entry(password, concealed: true), isRevealed: false) == EntryPreview.mask)
        #expect(!EntryPreview.mask.contains(password.prefix(1)))
    }

    @Test func revealedPasswordIsSanitized() {
        let password = entry("hun\u{202E}ter2\n\n\nsecond\nthird", concealed: true)
        #expect(EntryPreview.rowText(for: password, isRevealed: true) == "hunter2\nsecond…")
    }

    @Test func plainEntryIsShownWhetherOrNotRevealed() {
        let plain = entry("hello", concealed: false)
        #expect(EntryPreview.rowText(for: plain, isRevealed: false) == "hello")
        #expect(EntryPreview.rowText(for: plain, isRevealed: true) == "hello")
    }
}
