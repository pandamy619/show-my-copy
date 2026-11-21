import Foundation

/// Styled text ready for the preview. `AppKitRichTextRenderer` makes it and the preview view draws it; the history
/// window only passes it along.
protocol RenderedRichText: Sendable {}

/// Turns copied RTF into styled text for the preview. Called off the main actor.
///
/// The result must be safe to show: read as RTF only (never guessed, so HTML can never load anything), without
/// attachments or links, with nothing that opens an app or reaches the network, and with the characters
/// `PreviewText` removes taken out.
protocol RichTextRendering: Sendable {
    /// The styled text of `rtf`, or nil when it cannot be read. The preview then shows the plain text.
    func render(rtf: Data) -> (any RenderedRichText)?
}

/// Limits for drawing copied rich text in the preview.
enum RichTextPreviewPolicy {
    /// Font sizes outside this range are clamped, so a 1-point or 500-point font stays readable in the preview.
    static let fontSizes: ClosedRange<Double> = 8...48

    static func clampedFontSize(_ size: Double) -> Double {
        clamped(size, to: fontSizes)
    }

    /// Spacing between characters (`.kern`), in points. Copied RTF can ask for metres of it.
    static let kerning: ClosedRange<Double> = -5...50
    /// Horizontal stretch of glyphs (`.expansion`) and slant (`.obliqueness`), as AppKit factors.
    static let glyphFactors: ClosedRange<Double> = -1...1
    /// Shift of the baseline (`.baselineOffset`), in points.
    static let baselineOffsets: ClosedRange<Double> = -50...50
    /// Space around and between lines and paragraphs, in points: line spacing, paragraph spacing, line heights.
    static let paragraphSpacings: ClosedRange<Double> = 0...200
    /// Indents of a paragraph, in points, from either side.
    static let indents: ClosedRange<Double> = 0...400
    /// How much taller than natural a line may be.
    static let lineHeightMultiples: ClosedRange<Double> = 0...4

    /// `value` within `range`; a value that is not a number becomes the range's lower bound.
    static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else {
            return range.lowerBound
        }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// Renders off the main actor. RTF up to 1 MB can take a moment to read.
    @concurrent
    static func render(_ rtf: Data, with renderer: any RichTextRendering) async -> (any RenderedRichText)? {
        guard let rendered = renderer.render(rtf: rtf) else {
            AppLogger.history.error("Could not read rich text for a preview; showing its plain text")
            return nil
        }
        return rendered
    }
}
