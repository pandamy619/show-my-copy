import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import ShowMyCopy

struct ImageIOThumbnailMakerTests {
    private let maker = ImageIOThumbnailMaker()

    /// A PNG of one colour, `width` by `height` pixels.
    private func png(width: Int, height: Int) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(output as CFMutableData, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @Test func measuresTheImageAndDrawsASmallPNG() throws {
        let inspection = try maker.inspect(try png(width: 1000, height: 500), maximumPixelSize: 256)
        #expect(inspection.pixelWidth == 1000)
        #expect(inspection.pixelHeight == 500)
        let thumbnail = try #require(inspection.thumbnail)
        #expect(thumbnail.pixelWidth == 256)
        #expect(thumbnail.pixelHeight == 128)
        #expect(thumbnail.pngData.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))

        // The thumbnail is itself a readable image of that size.
        let again = try maker.inspect(thumbnail.pngData, maximumPixelSize: 256)
        #expect(again.pixelWidth == 256)
        #expect(again.pixelHeight == 128)
    }

    @Test func smallImageIsNotEnlarged() throws {
        let inspection = try maker.inspect(try png(width: 40, height: 30), maximumPixelSize: 256)
        let thumbnail = try #require(inspection.thumbnail)
        #expect(thumbnail.pixelWidth <= 40)
        #expect(thumbnail.pixelHeight <= 30)
    }

    @Test func tallImageIsLimitedByItsHeight() throws {
        let inspection = try maker.inspect(try png(width: 300, height: 1200), maximumPixelSize: 256)
        let thumbnail = try #require(inspection.thumbnail)
        #expect(thumbnail.pixelHeight == 256)
        #expect(thumbnail.pixelWidth == 64)
    }

    @Test func dataThatIsNotAnImageIsRejected() {
        #expect(throws: ThumbnailError.notAnImage) {
            try maker.inspect(Data("not an image".utf8), maximumPixelSize: 256)
        }
        #expect(throws: ThumbnailError.notAnImage) {
            try maker.inspect(Data(), maximumPixelSize: 256)
        }
    }

    @Test func ingestorStoresARealImageWithItsThumbnail() async throws {
        let blobs = InMemoryBlobStore()
        let ingestor = ImageIngestor(blobs: blobs, thumbnails: maker)
        let data = try png(width: 800, height: 600)
        let ingested = try await ingestor.ingest(CapturedImage(data: data, typeIdentifier: "public.png"), known: [:])
        #expect(ingested.reference.pixelWidth == 800)
        #expect(ingested.reference.pixelHeight == 600)
        #expect(try blobs.read(ingested.reference.blobID) == data)
        let thumbnail = try #require(ingested.reference.thumbnail)
        #expect(thumbnail.pixelWidth == 256)
        #expect(thumbnail.pixelHeight == 192)
    }
}
