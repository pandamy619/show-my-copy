import CoreGraphics
import Foundation
import ImageIO
import Testing

/// PNG files built byte by byte, to declare sizes no encoder would be asked for.
enum CraftedPNG {
    /// A valid PNG of `width` × `height` black 1-bit grey pixels. All-zero rows compress about 1000 to 1, so even
    /// 120 megapixels take a few kilobytes: the shape of a decompression bomb, small enough to decode in a test.
    static func blank(width: Int, height: Int) throws -> Data {
        let rowBytes = 1 + (width + 7) / 8  // a filter byte (0, none), then the pixels
        let raw = Data(count: rowBytes * height)
        let deflated = try (raw as NSData).compressed(using: .zlib) as Data
        // zlib wrapper: header (deflate, 32 KB window, no dictionary), raw deflate, Adler-32 of the raw bytes.
        // For all-zero bytes Adler-32 is a = 1 and b = n mod 65521.
        var zlib = Data([0x78, 0x01])
        zlib.append(deflated)
        zlib.append(bigEndian(UInt32(raw.count % 65521) << 16 | 1))
        return signature + chunk("IHDR", header(width: width, height: height, bitDepth: 1, colorType: 0))
            + chunk("IDAT", zlib) + chunk("IEND", Data())
    }

    /// A PNG of a few bytes whose header declares `width` × `height` RGBA pixels, followed by a little image data
    /// and the end: what a bomb looks like to a reader that trusts the header.
    static func headerOnly(width: Int, height: Int) -> Data {
        signature + chunk("IHDR", header(width: width, height: height, bitDepth: 8, colorType: 6))
            + chunk("IDAT", Data([0x78, 0x01, 0x01, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x01]))
            + chunk("IEND", Data())
    }

    /// `width` × `height` pixels of one colour, written by ImageIO as `type`.
    static func encoded(width: Int, height: Int, as type: String) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(output as CFMutableData, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private static let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    private static func header(width: Int, height: Int, bitDepth: UInt8, colorType: UInt8) -> Data {
        // Width, height, bit depth, colour type, compression, filter, interlace.
        bigEndian(UInt32(width)) + bigEndian(UInt32(height)) + Data([bitDepth, colorType, 0, 0, 0])
    }

    private static func chunk(_ type: String, _ data: Data) -> Data {
        let typed = Data(type.utf8) + data
        return bigEndian(UInt32(data.count)) + typed + bigEndian(crc32(typed))
    }

    private static func bigEndian(_ value: UInt32) -> Data {
        Data([24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) })
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return ~crc
    }
}
