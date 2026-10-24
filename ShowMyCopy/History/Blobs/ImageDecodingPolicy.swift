import Foundation

/// The image formats the app lets ImageIO decode. ImageIO can read many more (RAW, EXR, PSD, ICNS, SVG and others),
/// and it picks the format from the bytes, not from the type the data was copied as. Every extra format is another
/// parser that untrusted data reaches, so anything else is rejected before ImageIO sees it.
enum ImageFormat: CaseIterable, Equatable, Sendable {
    case png, jpeg, heic, tiff, gif, webp, bmp

    /// The Uniform Type Identifier of the format, as ImageIO and the pasteboard name it.
    var typeIdentifier: String {
        switch self {
        case .png: "public.png"
        case .jpeg: "public.jpeg"
        case .heic: "public.heic"
        case .tiff: "public.tiff"
        case .gif: "com.compuserve.gif"
        case .webp: "org.webmproject.webp"
        case .bmp: "com.microsoft.bmp"
        }
    }

    /// The format a type identifier names exactly, or nil for any other type: subtypes such as RAW formats (which
    /// are TIFF inside) or AVIF (which is HEIF inside) are not these formats. `public.heif` counts as HEIC: it is the
    /// same container and decoder, and ImageIO reports some HEIC photos with it.
    init?(typeIdentifier: String) {
        if typeIdentifier == "public.heif" {
            self = .heic
            return
        }
        guard let format = Self.allCases.first(where: { $0.typeIdentifier == typeIdentifier }) else {
            return nil
        }
        self = format
    }

    /// The format whose signature `data` starts with, or nil. Only the first bytes are looked at; this decides
    /// whether ImageIO is asked at all, and ImageIO must then read the data as the same format.
    init?(sniffing data: Data) {
        let bytes = [UInt8](data.prefix(32))
        guard let format = Self.allCases.first(where: { $0.matches(bytes) }) else {
            return nil
        }
        self = format
    }

    /// ISO base media brands of HEIF images coded with HEVC, and the generic HEIF brands. AVIF also uses the generic
    /// ones; ImageIO then reports it as AVIF and the data is rejected.
    private static let heifBrands: Set<String> = [
        "heic", "heix", "heim", "heis", "hevc", "hevx", "hevm", "hevs", "mif1", "msf1",
    ]

    /// Sizes of the BMP info headers ImageIO reads (BITMAPCOREHEADER to BITMAPV5HEADER). Two bytes ("BM") alone are
    /// too weak a signature.
    private static let bmpInfoHeaderSizes: Set<UInt32> = [12, 40, 52, 56, 64, 108, 124]

    private func matches(_ bytes: [UInt8]) -> Bool {
        switch self {
        case .png:
            bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        case .jpeg:
            bytes.starts(with: [0xFF, 0xD8, 0xFF])
        case .heic:
            bytes.count >= 12 && Self.ascii(bytes[4..<8]) == "ftyp"
                && Self.heifBrands.contains(Self.ascii(bytes[8..<12]))
        case .tiff:
            bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A])
        case .gif:
            bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8))
        case .webp:
            bytes.count >= 12 && Self.ascii(bytes[0..<4]) == "RIFF" && Self.ascii(bytes[8..<12]) == "WEBP"
        case .bmp:
            bytes.count >= 18 && bytes.starts(with: [0x42, 0x4D])
                && Self.bmpInfoHeaderSizes.contains(Self.littleEndian(bytes[14..<18]))
        }
    }

    private static func ascii(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes, as: Unicode.ASCII.self)
    }

    private static func littleEndian(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }
}

/// What image data must pass before ImageIO decodes any of it: at capture (`ImageIOThumbnailMaker`), in the history
/// window (`ImageIOPreviewDecoder`) and for copied image files (`QuickLookFileThumbnailMaker`).
///
/// 1. Its bytes start with the signature of an allowlisted `ImageFormat`, the same one as the type it was copied
///    as, when that is known.
/// 2. ImageIO, given that format as a hint, reads it as that same format (checked by the platform code).
/// 3. The width and height in its header give at most `maximumPixelCount` pixels. Reading the header decodes no
///    pixels; an image over the limit is never decoded.
enum ImageDecodingPolicy {
    /// The most pixels an image may have to be decoded, about 120 megapixels.
    ///
    /// Compressed size says little about decoded size: a 20 MB PNG of one colour can declare 65535 × 65535 pixels
    /// (4.3 gigapixels, 17 GB as RGBA), and drawing a thumbnail of a PNG, TIFF, GIF or BMP still inflates every row.
    /// 120 MP is above every photo people copy: phone cameras (48 MP), full-frame cameras (61 MP) and the
    /// 100-megapixel medium-format cameras, whose images are about 102 MP (11648 × 8736). At 4 bytes a pixel it
    /// bounds a full decode to about 480 MB, and it rules out the gigapixel images a decompression bomb declares.
    /// Larger images are still recorded (the bytes, their size and type), just without a thumbnail or preview.
    static let maximumPixelCount = 120_000_000

    /// The allowlisted format of `data`, or nil when its bytes are not one, or are not the format `declaredType`
    /// names. `declaredType` is the type the data was copied as, nil when it is not known.
    static func format(of data: Data, declaredType: String?) -> ImageFormat? {
        guard let sniffed = ImageFormat(sniffing: data) else {
            return nil
        }
        if let declaredType, ImageFormat(typeIdentifier: declaredType) != sniffed {
            return nil
        }
        return sniffed
    }

    /// Whether the type ImageIO detected (`CGImageSourceGetType`) is `format`. ImageIO detects the format from the
    /// bytes, so this catches data that starts like an allowlisted format but is read as another, such as a RAW
    /// photo, which starts like a TIFF.
    static func accepts(detectedType: String?, for format: ImageFormat) -> Bool {
        detectedType.flatMap(ImageFormat.init(typeIdentifier:)) == format
    }

    /// Whether an image of this size, from its header, may be decoded. False for a size that is not positive or
    /// whose pixel count overflows.
    static func allowsDecoding(pixelWidth: Int, pixelHeight: Int) -> Bool {
        guard pixelWidth > 0, pixelHeight > 0 else {
            return false
        }
        let (pixels, overflow) = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        return !overflow && pixels <= maximumPixelCount
    }
}
