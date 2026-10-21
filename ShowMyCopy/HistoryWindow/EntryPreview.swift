import Foundation

/// Short, safe text for showing an entry in a list.
///
/// Copied text can be huge and can contain control characters or Unicode direction overrides that make it
/// look like something else. The preview keeps at most `maximumLines` non-blank lines and `maximumCharacters`
/// characters, drops invisible control characters and collapses runs of whitespace.
enum EntryPreview {
    static let maximumLines = 2
    static let maximumCharacters = 300
    static let ellipsis = "…"
    /// Shown in place of a concealed entry. Its length is fixed, so it says nothing about the password.
    static let mask = "••••••••"

    /// The text a history row shows: the mask for a concealed entry the user has not revealed, otherwise the
    /// sanitized preview made when the entry was recorded.
    static func rowText(for entry: ClipboardEntry, isRevealed: Bool) -> String {
        entry.isConcealed && !isRevealed ? mask : entry.previewText
    }

    /// Builds the preview without walking more of the text than it needs.
    static func text(_ text: String) -> String {
        var builder = Builder()
        var iterator = text.unicodeScalars.makeIterator()
        while !builder.isFull, let scalar = iterator.next() {
            builder.append(scalar)
        }
        var truncated = builder.isFull
        if truncated {
            // Mark the preview as cut off only if visible text follows.
            truncated = false
            while let scalar = iterator.next() {
                if !isRemoved(scalar), !isLineBreak(scalar), !scalar.properties.isWhitespace {
                    truncated = true
                    break
                }
            }
        }
        var remaining = maximumCharacters
        var lines: [String] = []
        for line in builder.finish() {
            guard remaining > 0 else {
                truncated = true
                break
            }
            if line.count > remaining {
                lines.append(String(line.prefix(remaining)))
                truncated = true
                break
            }
            lines.append(line)
            remaining -= line.count
        }
        let preview = lines.joined(separator: "\n")
        return truncated ? preview + ellipsis : preview
    }

    /// A short localized time such as "now", "5 min. ago" or "yesterday". The last minute is shown as "now".
    static func relativeTime(of date: Date, now: Date, locale: Locale = .autoupdatingCurrent) -> String {
        let elapsed = now.timeIntervalSince(date)
        let shown = elapsed < 60 ? 0 : elapsed
        let style = Date.RelativeFormatStyle(presentation: .named, unitsStyle: .abbreviated, locale: locale)
        // The style always formats against the current time, so shift the date by the same elapsed time.
        return style.format(Date() - shown)
    }

    /// Control characters and bidirectional formatting characters that must never reach the screen.
    static func isRemoved(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x202A...0x202E, 0x2066...0x2069, 0x200E, 0x200F, 0x061C:
            return true
        default:
            return scalar.properties.generalCategory == .control && !isLineBreak(scalar) && scalar != "\t"
        }
    }

    static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A...0x0D, 0x85, 0x2028, 0x2029:
            return true
        default:
            return false
        }
    }

    private struct Builder {
        /// Enough scalars for `maximumCharacters` characters with a few combining marks each.
        private static let maximumScalarsPerLine = EntryPreview.maximumCharacters * 4

        private var lines: [String.UnicodeScalarView] = []
        private var line = String.UnicodeScalarView()
        private var pendingSpace = false

        var isFull: Bool {
            lines.count == EntryPreview.maximumLines || line.count >= Self.maximumScalarsPerLine
        }

        mutating func append(_ scalar: Unicode.Scalar) {
            if EntryPreview.isRemoved(scalar) {
                return
            }
            if EntryPreview.isLineBreak(scalar) {
                endLine()
                return
            }
            if scalar.properties.isWhitespace {
                pendingSpace = !line.isEmpty
                return
            }
            if pendingSpace {
                line.append(" ")
                pendingSpace = false
            }
            line.append(scalar)
        }

        mutating func finish() -> [String] {
            endLine()
            return lines.map { String($0) }
        }

        private mutating func endLine() {
            if !line.isEmpty {
                lines.append(line)
            }
            line = String.UnicodeScalarView()
            pendingSpace = false
        }
    }
}
