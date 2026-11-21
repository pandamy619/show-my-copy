import AppKit

/// Styled text made by `AppKitRichTextRenderer`.
///
/// `@unchecked Sendable`: the attributed string is an immutable copy that nothing changes after rendering, and
/// immutable `NSAttributedString`s are safe to read from any thread.
struct AppKitRenderedRichText: RenderedRichText, @unchecked Sendable {
    let attributedString: NSAttributedString
}

/// Reads copied RTF with AppKit and keeps only what is safe and useful to show.
///
/// - The data is read as RTF, never guessed: guessing could read it as HTML, which can load resources.
/// - Only text styling is kept (`keptAttributes`). Attachments (pictures embedded in the RTF), links, tool tips,
///   cursors and anything else are dropped, so nothing in the preview can open a link, an app or a file.
/// - The object replacement characters attachments leave behind, control characters and Unicode direction
///   overrides are removed, as everywhere in the history window (`PreviewText`).
/// - Font sizes, kerning, glyph factors, baseline offsets, indents and spacing are clamped
///   (`RichTextPreviewPolicy`), so laying the text out stays cheap whatever the RTF asks for, and the text is cut
///   after `PreviewText.maximumCharacters` characters.
///
/// Reading RTF with AppKit never touches the network. It runs off the main actor: unlike HTML, RTF may be read on
/// any thread.
struct AppKitRichTextRenderer: RichTextRendering {
    static let keptAttributes: Set<NSAttributedString.Key> = [
        .font, .foregroundColor, .backgroundColor, .underlineStyle, .underlineColor, .strikethroughStyle,
        .strikethroughColor, .paragraphStyle, .kern, .baselineOffset, .superscript, .obliqueness, .expansion,
        .ligature,
    ]

    func render(rtf: Data) -> (any RenderedRichText)? {
        let text: NSMutableAttributedString
        do {
            text = try NSMutableAttributedString(
                data: rtf,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
        } catch {
            return nil
        }
        Self.keepStylingOnly(text)
        Self.removeHiddenCharacters(text)
        Self.truncate(text)
        return AppKitRenderedRichText(attributedString: NSAttributedString(attributedString: text))
    }

    private static func keepStylingOnly(_ text: NSMutableAttributedString) {
        let whole = NSRange(location: 0, length: text.length)
        // Changing attributes inside the range given to the block is allowed while enumerating.
        text.enumerateAttributes(in: whole, options: []) { attributes, range, _ in
            for key in attributes.keys where !keptAttributes.contains(key) {
                text.removeAttribute(key, range: range)
            }
            if let font = attributes[.font] as? NSFont {
                let size = CGFloat(RichTextPreviewPolicy.clampedFontSize(Double(font.pointSize)))
                if size != font.pointSize, let resized = NSFont(descriptor: font.fontDescriptor, size: size) {
                    text.addAttribute(.font, value: resized, range: range)
                }
            }
            clampNumbers(in: attributes, range: range, of: text)
            if let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle {
                text.addAttribute(.paragraphStyle, value: clamped(paragraph), range: range)
            }
        }
    }

    /// The attributes that are plain numbers, each within its range (`RichTextPreviewPolicy`).
    private static func clampNumbers(
        in attributes: [NSAttributedString.Key: Any], range: NSRange, of text: NSMutableAttributedString
    ) {
        let ranges: [(NSAttributedString.Key, ClosedRange<Double>)] = [
            (.kern, RichTextPreviewPolicy.kerning),
            (.expansion, RichTextPreviewPolicy.glyphFactors),
            (.obliqueness, RichTextPreviewPolicy.glyphFactors),
            (.baselineOffset, RichTextPreviewPolicy.baselineOffsets),
        ]
        for (key, allowed) in ranges {
            guard let value = attributes[key] as? NSNumber else {
                continue
            }
            let clamped = RichTextPreviewPolicy.clamped(value.doubleValue, to: allowed)
            if clamped != value.doubleValue {
                text.addAttribute(key, value: NSNumber(value: clamped), range: range)
            }
        }
    }

    /// The paragraph style with its spacing, indents and line heights within their ranges, and without tab stops of
    /// its own: a thousand of them would each be laid out. The default tab interval is clamped like an indent.
    private static func clamped(_ style: NSParagraphStyle) -> NSParagraphStyle {
        guard let paragraph = style.mutableCopy() as? NSMutableParagraphStyle else {
            return style
        }
        let spacing = RichTextPreviewPolicy.paragraphSpacings
        let indents = RichTextPreviewPolicy.indents
        paragraph.lineSpacing = clamp(paragraph.lineSpacing, spacing)
        paragraph.paragraphSpacing = clamp(paragraph.paragraphSpacing, spacing)
        paragraph.paragraphSpacingBefore = clamp(paragraph.paragraphSpacingBefore, spacing)
        paragraph.minimumLineHeight = clamp(paragraph.minimumLineHeight, spacing)
        paragraph.maximumLineHeight = clamp(paragraph.maximumLineHeight, spacing)
        paragraph.lineHeightMultiple = clamp(paragraph.lineHeightMultiple, RichTextPreviewPolicy.lineHeightMultiples)
        paragraph.headIndent = clamp(paragraph.headIndent, indents)
        paragraph.firstLineHeadIndent = clamp(paragraph.firstLineHeadIndent, indents)
        // A tail indent is measured from the leading edge when positive and from the trailing edge when negative.
        paragraph.tailIndent = paragraph.tailIndent < 0 ? -clamp(-paragraph.tailIndent, indents) : 0
        paragraph.defaultTabInterval = clamp(paragraph.defaultTabInterval, indents)
        paragraph.tabStops = []
        return paragraph
    }

    private static func clamp(_ value: CGFloat, _ range: ClosedRange<Double>) -> CGFloat {
        CGFloat(RichTextPreviewPolicy.clamped(Double(value), to: range))
    }

    private static func removeHiddenCharacters(_ text: NSMutableAttributedString) {
        // From the end, so the earlier ranges stay valid.
        for range in PreviewText.removedRanges(in: text.string).reversed() {
            text.deleteCharacters(in: NSRange(location: range.lowerBound, length: range.count))
        }
    }

    private static func truncate(_ text: NSMutableAttributedString) {
        guard let cut = PreviewText.truncationOffset(in: text.string) else {
            return
        }
        let attributes = cut > 0 ? text.attributes(at: cut - 1, effectiveRange: nil) : [:]
        text.deleteCharacters(in: NSRange(location: cut, length: text.length - cut))
        text.append(NSAttributedString(string: EntryPreview.ellipsis, attributes: attributes))
    }
}
