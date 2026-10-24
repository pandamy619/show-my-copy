import Foundation

/// Text for the large preview of an entry.
///
/// Unlike a row (`EntryPreview`), the preview keeps line breaks and tabs and shows much more text, but the same
/// characters never reach the screen: control characters and Unicode direction overrides, which can make text look
/// like something else. The object replacement character goes too: it stands for an attachment, and the preview
/// shows none.
enum PreviewText {
    /// The preview shows at most this many characters. Longer text ends with an ellipsis.
    static let maximumCharacters = 20_000

    static func isRemoved(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\u{FFFC}" || EntryPreview.isRemoved(scalar)
    }

    /// `text` without the removed characters, cut after `maximumCharacters` characters. Stops reading the text as
    /// soon as it has enough, so a huge entry costs no more than a short one.
    static func sanitized(_ text: String, maximumCharacters: Int = maximumCharacters) -> String {
        var result = ""
        var count = 0
        var isTruncated = false
        for character in text {
            let kept = character.unicodeScalars.filter { !isRemoved($0) }
            guard !kept.isEmpty else {
                continue
            }
            guard count < maximumCharacters else {
                isTruncated = true
                break
            }
            result.unicodeScalars.append(contentsOf: kept)
            count += 1
        }
        return isTruncated ? result + EntryPreview.ellipsis : result
    }

    /// The UTF-16 ranges of the removed characters in `text`, in order, for deleting them from an attributed string.
    static func removedRanges(in text: String) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var offset = 0
        for scalar in text.unicodeScalars {
            let length = scalar.utf16.count
            if isRemoved(scalar) {
                if let last = ranges.last, last.upperBound == offset {
                    ranges[ranges.count - 1] = last.lowerBound..<(offset + length)
                } else {
                    ranges.append(offset..<(offset + length))
                }
            }
            offset += length
        }
        return ranges
    }

    /// The UTF-16 offset at which to cut `text` so it keeps `maximumCharacters` characters, or nil when it is not
    /// longer than that. The cut is always between two characters, never inside one.
    static func truncationOffset(in text: String, maximumCharacters: Int = maximumCharacters) -> Int? {
        guard let cut = text.index(text.startIndex, offsetBy: max(maximumCharacters, 0), limitedBy: text.endIndex),
            cut < text.endIndex
        else {
            return nil
        }
        return text.utf16.distance(from: text.startIndex, to: cut)
    }
}
