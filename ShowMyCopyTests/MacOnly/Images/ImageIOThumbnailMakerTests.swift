import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import ShowMyCopy

struct ImageIOThumbnailMakerTests {
    private let maker = ImageIOThumbnailMaker()

    /// A PNG of one colour, `width` by `height` pixels.
    private func png(width: Int, height: Int) throws -> Data {
        try CraftedPNG.encoded(width: width, height: height, as: "public.png")
    }

    private func inspect(_ data: Data, as type: String = "public.png") throws -> ImageInspection {
        try maker.inspect(data, declaredType: type, maximumPixelSize: 256)
    }

    @Test func measuresTheImageAndDrawsASmallPNG() throws {
        let inspection = try inspect(try png(width: 1000, height: 500))
        #expect(inspection.pixelWidth == 1000)
        #expect(inspection.pixelHeight == 500)
        let thumbnail = try #require(inspection.thumbnail)
        #expect(thumbnail.pixelWidth == 256)
        #expect(thumbnail.pixelHeight == 128)
        #expect(thumbnail.pngData.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))

        // The thumbnail is itself a readable image of that size.
        let again = try inspect(thumbnail.pngData)
        #expect(again.pixelWidth == 256)
        #expect(again.pixelHeight == 128)
    }

    @Test func smallImageIsNotEnlarged() throws {
        let inspection = try inspect(try png(width: 40, height: 30))
        let thumbnail = try #require(inspection.thumbnail)
        #expect(thumbnail.pixelWidth <= 40)
        #expect(thumbnail.pixelHeight <= 30)
    }

    @Test func tallImageIsLimitedByItsHeight() throws {
        let inspection = try inspect(try png(width: 300, height: 1200))
        let thumbnail = try #require(inspection.thumbnail)
        #expect(thumbnail.pixelHeight == 256)
        #expect(thumbnail.pixelWidth == 64)
    }

    @Test func dataThatIsNotAnImageIsRejected() {
        #expect(throws: ThumbnailError.notAnImage) {
            try inspect(Data("not an image".utf8))
        }
        #expect(throws: ThumbnailError.notAnImage) {
            try inspect(Data())
        }
    }

    @Test func bombHeaderIsMeasuredButNotDecoded() throws {
        let bomb = CraftedPNG.headerOnly(width: 60000, height: 60000)
        #expect(bomb.count < 200)
        let inspection = try inspect(bomb)
        #expect(inspection.pixelWidth == 60000)
        #expect(inspection.pixelHeight == 60000)
        #expect(inspection.thumbnail == nil)
    }

    /// A valid image built the same way gets a thumbnail at a smaller size, so only the pixel count stops it.
    @Test func imageOverThePixelLimitIsRecordedWithoutAThumbnail() throws {
        let small = try CraftedPNG.blank(width: 2000, height: 2000)
        #expect(try inspect(small).thumbnail != nil)
        #expect(!ImageDecodingPolicy.allowsDecoding(pixelWidth: 11000, pixelHeight: 11000))

        let over = try CraftedPNG.blank(width: 11000, height: 11000)
        #expect(over.count < ImageContentReader.defaultMaximumBytes)
        let inspection = try inspect(over)
        #expect(inspection.pixelWidth == 11000)
        #expect(inspection.pixelHeight == 11000)
        #expect(inspection.thumbnail == nil)
    }

    @Test func ingestorStoresAnImageOverThePixelLimitWithoutAThumbnail() async throws {
        let blobs = InMemoryBlobStore()
        let ingestor = ImageIngestor(thumbnails: maker)
        let reservation = InFlightBlobStore(base: blobs).reservation()
        let data = try CraftedPNG.blank(width: 11000, height: 11000)
        let ingested = try await ingestor.ingest(
            CapturedImage(data: data, typeIdentifier: "public.png"), as: reservation.newID(), known: [:],
            reservation: reservation)
        #expect(ingested.pixelWidth == 11000)
        #expect(ingested.thumbnail == nil)
        #expect(blobs.allIDs() == [ingested.blobID])
    }

    @Test func dataOfAnotherFormatThanItWasCopiedAsIsRejected() throws {
        let jpeg = try CraftedPNG.encoded(width: 40, height: 30, as: "public.jpeg")
        let gif = try CraftedPNG.encoded(width: 40, height: 30, as: "com.compuserve.gif")
        let tiff = try CraftedPNG.encoded(width: 40, height: 30, as: "public.tiff")
        for (data, type) in [(jpeg, "public.jpeg"), (gif, "com.compuserve.gif"), (tiff, "public.tiff")] {
            #expect(try inspect(data, as: type).pixelWidth == 40, "\(type)")
            #expect(throws: ThumbnailError.notAnImage, "\(type) copied as PNG") {
                try inspect(data, as: "public.png")
            }
        }
        #expect(throws: ThumbnailError.notAnImage) {
            try inspect(try png(width: 40, height: 30), as: "public.tiff")
        }
    }

    @Test func formatsOutsideTheAllowlistAreRejectedWhateverTheyAreCopiedAs() throws {
        let jpeg2000 = try CraftedPNG.encoded(width: 40, height: 30, as: "public.jpeg-2000")
        for type in ["public.jpeg-2000", "public.png", "public.tiff"] {
            #expect(throws: ThumbnailError.notAnImage, "\(type)") {
                try inspect(jpeg2000, as: type)
            }
        }
    }

    @Test func ingestorStoresARealImageWithItsThumbnail() async throws {
        let blobs = InMemoryBlobStore()
        let ingestor = ImageIngestor(thumbnails: maker)
        let reservation = InFlightBlobStore(base: blobs).reservation()
        let data = try png(width: 800, height: 600)
        let ingested = try await ingestor.ingest(
            CapturedImage(data: data, typeIdentifier: "public.png"), as: reservation.newID(), known: [:],
            reservation: reservation)
        #expect(ingested.pixelWidth == 800)
        #expect(ingested.pixelHeight == 600)
        #expect(try blobs.read(ingested.blobID) == data)
        let thumbnail = try #require(ingested.thumbnail)
        #expect(thumbnail.pixelWidth == 256)
        #expect(thumbnail.pixelHeight == 192)
    }
}
