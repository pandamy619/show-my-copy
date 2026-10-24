import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import ShowMyCopy

struct ImageIOPreviewDecoderTests {
    private let decoder = ImageIOPreviewDecoder()

    /// A PNG of one colour, `width` by `height` pixels.
    private func png(width: Int, height: Int) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(output as CFMutableData, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @Test func decodesAtMostTheRequestedSize() throws {
        let image = try #require(decoder.decode(try png(width: 3000, height: 1500), maximumPixelSize: 2048))
        #expect(image.pixelWidth == 2048)
        #expect(image.pixelHeight == 1024)
        #expect(image is CGPreviewImage)
    }

    @Test func doesNotEnlargeASmallImage() throws {
        let image = try #require(decoder.decode(try png(width: 40, height: 30), maximumPixelSize: 256))
        #expect(image.pixelWidth <= 40)
        #expect(image.pixelHeight <= 30)
    }

    @Test func rejectsDataThatIsNotAnImage() {
        #expect(decoder.decode(Data("not an image".utf8), maximumPixelSize: 256) == nil)
        #expect(decoder.decode(Data(), maximumPixelSize: 256) == nil)
    }

    @Test func imageOverThePixelLimitIsNotDecoded() throws {
        // Built the same way, but small enough: decoded.
        let small = try CraftedPNG.blank(width: 3000, height: 3000)
        let image = try #require(decoder.decode(small, maximumPixelSize: 2048))
        #expect(image.pixelWidth == 2048)
        #expect(decoder.decode(try CraftedPNG.blank(width: 11000, height: 11000), maximumPixelSize: 2048) == nil)
        #expect(decoder.decode(CraftedPNG.headerOnly(width: 60000, height: 60000), maximumPixelSize: 256) == nil)
    }

    @Test func decodesOnlyAllowedFormats() throws {
        for type in ["public.jpeg", "com.compuserve.gif", "public.tiff", "com.microsoft.bmp"] {
            let data = try CraftedPNG.encoded(width: 40, height: 30, as: type)
            #expect(decoder.decode(data, maximumPixelSize: 256) != nil, "\(type)")
        }
        let jpeg2000 = try CraftedPNG.encoded(width: 40, height: 30, as: "public.jpeg-2000")
        #expect(decoder.decode(jpeg2000, maximumPixelSize: 256) == nil)
    }

    @Test @MainActor func thumbnailProviderDecodesARealThumbnailOffTheMainActor() async throws {
        let blobs = InMemoryBlobStore()
        let ingestor = ImageIngestor(thumbnails: ImageIOThumbnailMaker())
        let captured = CapturedImage(data: try png(width: 800, height: 600), typeIdentifier: "public.png")
        let reservation = InFlightBlobStore(base: blobs).reservation()
        let reference = try await ingestor.ingest(
            captured, as: reservation.newID(), known: [:], reservation: reservation)
        let provider = ThumbnailProvider(blobs: blobs, decoder: decoder)
        let thumbnail = try #require(await provider.thumbnail(for: reference))
        #expect(thumbnail.pixelWidth == 256)
        #expect(thumbnail.pixelHeight == 192)
    }
}

struct AppKitRichTextRendererTests {
    private let renderer = AppKitRichTextRenderer()

    private func render(_ rtf: String) throws -> NSAttributedString {
        let rendered = try #require(renderer.render(rtf: Data(rtf.utf8)) as? AppKitRenderedRichText)
        return rendered.attributedString
    }

    private func has(_ key: NSAttributedString.Key, in text: NSAttributedString) -> Bool {
        var found = false
        text.enumerateAttribute(key, in: NSRange(location: 0, length: text.length), options: []) { value, _, _ in
            found = found || value != nil
        }
        return found
    }

    @Test func keepsTheTextAndItsStyling() throws {
        let text = try render(#"{\rtf1\ansi{\fonttbl\f0 Helvetica;}\f0\fs28 {\b Bold} plain}"#)
        #expect(text.string == "Bold plain")
        let font = try #require(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(font.pointSize == 14)
    }

    @Test func dropsLinks() throws {
        let rtf = #"{\rtf1\ansi {\field{\*\fldinst{HYPERLINK "https://example.com/"}}{\fldrslt click}} here}"#
        let text = try render(rtf)
        #expect(text.string.contains("click"))
        #expect(!has(.link, in: text))
    }

    @Test func dropsAttachmentsAndTheirPlaceholders() throws {
        // A 1 × 1 PNG embedded in the RTF.
        let picture =
            "89504e470d0a1a0a0000000d4948445200000001000000010806000000"
            + "1f15c4890000000d49444154789c6360000002000154a24f5d0000000049454e44ae426082"
        let text = try render(#"{\rtf1\ansi before{\pict\pngblip\picw1\pich1 "# + picture + "}after}")
        #expect(!text.string.contains("\u{FFFC}"))
        #expect(text.string.contains("before"))
        #expect(text.string.contains("after"))
        #expect(!has(.attachment, in: text))
    }

    @Test func keepsOnlyStylingAttributes() throws {
        let text = try render(#"{\rtf1\ansi{\colortbl;\red255\green0\blue0;}\cf1\ul Red underlined}"#)
        let whole = NSRange(location: 0, length: text.length)
        text.enumerateAttributes(in: whole, options: []) { attributes, _, _ in
            #expect(attributes.keys.allSatisfy { AppKitRichTextRenderer.keptAttributes.contains($0) })
        }
        #expect(text.attribute(.underlineStyle, at: 0, effectiveRange: nil) != nil)
    }

    @Test func removesDirectionOverrides() throws {
        // `\u8238` is U+202E (right-to-left override) written as an RTF Unicode escape.
        let text = try render(#"{\rtf1\ansi abc\u8238?def}"#)
        #expect(text.string == "abcdef")
    }

    @Test func clampsHugeFonts() throws {
        let text = try render(#"{\rtf1\ansi{\fonttbl\f0 Helvetica;}\f0\fs1000 Huge}"#)
        let font = try #require(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize == 48)
    }

    @Test func cutsVeryLongText() throws {
        let long = String(repeating: "a", count: PreviewText.maximumCharacters + 10)
        let text = try render(#"{\rtf1\ansi "# + long + "}")
        #expect(text.length == PreviewText.maximumCharacters + 1)
        #expect(text.string.hasSuffix(EntryPreview.ellipsis))
    }

    @Test func htmlIsNotReadAsHTML() throws {
        // Read as RTF only: HTML is never interpreted, so it cannot load anything.
        let html = Data(#"<html><body><img src="https://example.com/a.png">hi</body></html>"#.utf8)
        if let rendered = renderer.render(rtf: html) as? AppKitRenderedRichText {
            #expect(!has(.attachment, in: rendered.attributedString))
        }
    }
}

@MainActor
struct WorkspaceFileIconProviderTests {
    @Test func givesAnIconForExistingAndMissingFiles() throws {
        let icons = WorkspaceFileIconProvider()
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(icons.icon(forPath: url.path(percentEncoded: false)).size.width > 0)
        #expect(icons.icon(forPath: "/no/such/file-\(UUID().uuidString).pdf").size.width > 0)
    }
}
