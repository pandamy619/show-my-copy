import Foundation

/// Styled text ready for the preview. Platform code makes it (`AppKitRichTextRenderer` on macOS) and the preview view
/// draws it; the history window only passes it along.
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
        guard size.isFinite else {
            return fontSizes.lowerBound
        }
        return min(max(size, fontSizes.lowerBound), fontSizes.upperBound)
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
