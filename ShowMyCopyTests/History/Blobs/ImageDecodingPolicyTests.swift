import Foundation
import Testing

@testable import ShowMyCopy

/// The first bytes of a file in each format, as real encoders write them.
enum ImageSignatures {
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13] + Array("IHDR".utf8))
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10] + Array("JFIF".utf8))
    static let heic = Data([0, 0, 0, 0x18] + Array("ftypheic".utf8) + [0, 0, 0, 0] + Array("mif1heic".utf8))
    static let tiffLittleEndian = Data([0x49, 0x49, 0x2A, 0x00, 8, 0, 0, 0])
    static let tiffBigEndian = Data([0x4D, 0x4D, 0x00, 0x2A, 0, 0, 0, 8])
    static let gif = Data(Array("GIF89a".utf8) + [1, 0, 1, 0])
    static let webp = Data(Array("RIFF".utf8) + [0x24, 0, 0, 0] + Array("WEBPVP8 ".utf8))
    /// "BM", file size, reserved, pixel offset, then a 40-byte BITMAPINFOHEADER.
    static let bmp = Data([0x42, 0x4D, 0x46, 0, 0, 0, 0, 0, 0, 0, 0x36, 0, 0, 0, 40, 0, 0, 0, 1, 0, 0, 0])
    /// AVIF: HEIF with an AV1 brand.
    static let avif = Data([0, 0, 0, 0x1C] + Array("ftypavif".utf8) + [0, 0, 0, 0] + Array("avifmif1".utf8))
    /// A Photoshop document, which ImageIO reads but the app does not allow.
    static let psd = Data(Array("8BPS".utf8) + [0, 1, 0, 0, 0, 0, 0, 0])
    static let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg"/>"#.utf8)
}

struct ImageFormatTests {
    @Test func recognizesEveryAllowedFormatByItsSignature() {
        #expect(ImageFormat(sniffing: ImageSignatures.png) == .png)
        #expect(ImageFormat(sniffing: ImageSignatures.jpeg) == .jpeg)
        #expect(ImageFormat(sniffing: ImageSignatures.heic) == .heic)
        #expect(ImageFormat(sniffing: ImageSignatures.tiffLittleEndian) == .tiff)
        #expect(ImageFormat(sniffing: ImageSignatures.tiffBigEndian) == .tiff)
        #expect(ImageFormat(sniffing: ImageSignatures.gif) == .gif)
        #expect(ImageFormat(sniffing: Data(Array("GIF87a".utf8))) == .gif)
        #expect(ImageFormat(sniffing: ImageSignatures.webp) == .webp)
        #expect(ImageFormat(sniffing: ImageSignatures.bmp) == .bmp)
    }

    @Test func rejectsOtherFormatsAndTruncatedSignatures() {
        #expect(ImageFormat(sniffing: ImageSignatures.avif) == nil)
        #expect(ImageFormat(sniffing: ImageSignatures.psd) == nil)
        #expect(ImageFormat(sniffing: ImageSignatures.svg) == nil)
        #expect(ImageFormat(sniffing: Data()) == nil)
        #expect(ImageFormat(sniffing: Data("not an image".utf8)) == nil)
        // The first bytes only, without the rest of the signature.
        #expect(ImageFormat(sniffing: ImageSignatures.png.prefix(4)) == nil)
        #expect(ImageFormat(sniffing: ImageSignatures.heic.prefix(8)) == nil)
        #expect(ImageFormat(sniffing: ImageSignatures.webp.prefix(8)) == nil)
        // "BM" without a known info header size is not taken for a BMP.
        #expect(ImageFormat(sniffing: Data(Array("BM".utf8) + Array(repeating: 0, count: 20))) == nil)
        // A RIFF file that is not WebP, such as a WAV.
        #expect(ImageFormat(sniffing: Data(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVE".utf8))) == nil)
    }

    @Test func typeIdentifiersAreMatchedExactly() {
        for format in ImageFormat.allCases {
            #expect(ImageFormat(typeIdentifier: format.typeIdentifier) == format)
        }
        #expect(ImageFormat(typeIdentifier: "public.heif") == .heic)
        for other in [
            "public.image", "public.svg-image", "com.adobe.pdf", "com.adobe.raw-image", "public.avif",
            "com.adobe.photoshop-image", "com.apple.icns", "com.ilm.openexr-image", "PUBLIC.PNG", "",
        ] {
            #expect(ImageFormat(typeIdentifier: other) == nil, "\(other)")
        }
    }

    @Test func everyTypeTheHistoryKeepsIsAllowed() {
        for type in ImageReference.supportedTypes {
            #expect(ImageFormat(typeIdentifier: type) != nil, "\(type)")
        }
    }
}

struct ImageDecodingPolicyTests {
    @Test func dataMustBeTheFormatItWasCopiedAs() {
        #expect(ImageDecodingPolicy.format(of: ImageSignatures.png, declaredType: "public.png") == .png)
        #expect(ImageDecodingPolicy.format(of: ImageSignatures.jpeg, declaredType: "public.jpeg") == .jpeg)
        #expect(ImageDecodingPolicy.format(of: ImageSignatures.heic, declaredType: "public.heic") == .heic)
        #expect(ImageDecodingPolicy.format(of: ImageSignatures.tiffBigEndian, declaredType: "public.tiff") == .tiff)
        // A WebP, GIF or JPEG copied as PNG never reaches ImageIO.
        #expect(ImageDecodingPolicy.format(of: ImageSignatures.webp, declaredType: "public.png") == nil)
        #expect(ImageDecodingPolicy.format(of: ImageSignatures.gif, declaredType: "public.png") == nil)
        #expect(ImageDecodingPolicy.format(of: ImageSignatures.jpeg, declaredType: "public.png") == nil)
        #expect(ImageDecodingPolicy.format(of: ImageSignatures.png, declaredType: "public.tiff") == nil)
        // Nor does anything that is not an allowed format, whatever it is copied as.
        #expect(ImageDecodingPolicy.format(of: ImageSignatures.psd, declaredType: "public.png") == nil)
        #expect(ImageDecodingPolicy.format(of: ImageSignatures.png, declaredType: "com.adobe.photoshop-image") == nil)
    }

    @Test func withoutADeclaredTypeAnyAllowedFormatPasses() {
        #expect(ImageDecodingPolicy.format(of: ImageSignatures.webp, declaredType: nil) == .webp)
        #expect(ImageDecodingPolicy.format(of: ImageSignatures.bmp, declaredType: nil) == .bmp)
        #expect(ImageDecodingPolicy.format(of: ImageSignatures.avif, declaredType: nil) == nil)
        #expect(ImageDecodingPolicy.format(of: Data(), declaredType: nil) == nil)
    }

    @Test func imageIOMustReadTheSameFormat() {
        #expect(ImageDecodingPolicy.accepts(detectedType: "public.png", for: .png))
        #expect(ImageDecodingPolicy.accepts(detectedType: "public.heif", for: .heic))
        // RAW photos start like TIFF; HEIF can hold AV1.
        #expect(!ImageDecodingPolicy.accepts(detectedType: "com.adobe.raw-image", for: .tiff))
        #expect(!ImageDecodingPolicy.accepts(detectedType: "com.canon.cr2-raw-image", for: .tiff))
        #expect(!ImageDecodingPolicy.accepts(detectedType: "public.avif", for: .heic))
        #expect(!ImageDecodingPolicy.accepts(detectedType: "org.webmproject.webp", for: .png))
        #expect(!ImageDecodingPolicy.accepts(detectedType: nil, for: .png))
    }

    @Test func pixelLimitIsAboutOneHundredTwentyMegapixels() {
        #expect(ImageDecodingPolicy.maximumPixelCount == 120_000_000)
        // A 100-megapixel medium-format photo and a 48-megapixel phone photo are decoded.
        #expect(ImageDecodingPolicy.allowsDecoding(pixelWidth: 11648, pixelHeight: 8736))
        #expect(ImageDecodingPolicy.allowsDecoding(pixelWidth: 8064, pixelHeight: 6048))
        #expect(ImageDecodingPolicy.allowsDecoding(pixelWidth: 1, pixelHeight: 1))
        // Exactly at the limit, and one row over it.
        #expect(ImageDecodingPolicy.allowsDecoding(pixelWidth: 12000, pixelHeight: 10000))
        #expect(!ImageDecodingPolicy.allowsDecoding(pixelWidth: 12000, pixelHeight: 10001))
        // A long strip is counted by its pixels, not its sides.
        #expect(ImageDecodingPolicy.allowsDecoding(pixelWidth: 1_000_000, pixelHeight: 120))
        #expect(!ImageDecodingPolicy.allowsDecoding(pixelWidth: 1_000_000, pixelHeight: 121))
    }

    @Test func decompressionBombsAndNonsenseSizesAreNotDecoded() {
        #expect(!ImageDecodingPolicy.allowsDecoding(pixelWidth: 65535, pixelHeight: 65535))
        #expect(!ImageDecodingPolicy.allowsDecoding(pixelWidth: 11000, pixelHeight: 11000))
        #expect(!ImageDecodingPolicy.allowsDecoding(pixelWidth: Int.max, pixelHeight: 2))
        #expect(!ImageDecodingPolicy.allowsDecoding(pixelWidth: 0, pixelHeight: 100))
        #expect(!ImageDecodingPolicy.allowsDecoding(pixelWidth: 100, pixelHeight: -1))
    }
}
