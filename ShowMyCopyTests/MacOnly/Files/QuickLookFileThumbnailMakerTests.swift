import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Testing

@testable import ShowMyCopy

/// Makes thumbnails of real files written to a temporary folder: a PNG and a short QuickTime movie.
struct QuickLookFileThumbnailMakerTests {
    private let maker = QuickLookFileThumbnailMaker()
    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appending(path: "QuickLookFileThumbnailMakerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func image(width: Int, height: Int) throws -> CGImage {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func writePNG(named name: String, width: Int, height: Int) throws -> URL {
        let url = folder.appending(path: name)
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try image(width: width, height: height), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// A one-second H.264 QuickTime movie of `width` by `height` pixels, in one colour.
    private func writeMovie(named name: String, width: Int, height: Int) async throws -> URL {
        let url = folder.appending(path: name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        #expect(writer.canAdd(input))
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let frame = try image(width: width, height: height)
        for index in 0..<10 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10))
            }
            let pool = try #require(adaptor.pixelBufferPool)
            var buffer: CVPixelBuffer?
            #expect(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let context = try #require(
                CGContext(
                    data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue))
            context.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 10)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    private func expectPNG(_ thumbnail: ImageInspection.Thumbnail, longerSide: Int) throws {
        #expect(thumbnail.pngData.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(max(thumbnail.pixelWidth, thumbnail.pixelHeight) <= longerSide)
        #expect(FileThumbnailIngestor.isValid(thumbnail))
        let source = try #require(CGImageSourceCreateWithData(thumbnail.pngData as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == thumbnail.pixelWidth)
        #expect(decoded.height == thumbnail.pixelHeight)
    }

    @Test func photoGetsAPNGThumbnail() async throws {
        let url = try writePNG(named: "photo.png", width: 1200, height: 800)
        #expect(maker.mediaKind(of: url) == .image)
        let thumbnail = try #require(await maker.thumbnail(of: url, maximumPixelSize: 256))
        try expectPNG(thumbnail, longerSide: 256)
    }

    @Test func movieGetsAFrameAsItsThumbnail() async throws {
        let url = try await writeMovie(named: "clip.mov", width: 640, height: 360)
        #expect(maker.mediaKind(of: url) == .movie)
        let thumbnail = try #require(await maker.thumbnail(of: url, maximumPixelSize: 256))
        try expectPNG(thumbnail, longerSide: 256)
    }

    @Test func otherFilesFoldersAndMissingFilesAreNotMedia() throws {
        let text = folder.appending(path: "notes.txt")
        try Data("notes".utf8).write(to: text)
        #expect(maker.mediaKind(of: text) == nil)
        #expect(maker.mediaKind(of: folder) == nil)
        #expect(maker.mediaKind(of: folder.appending(path: "missing.jpg")) == nil)
        #expect(maker.mediaKind(of: try #require(URL(string: "https://example.com/a.jpg"))) == nil)
    }

    private func write(_ data: Data, named name: String) throws -> URL {
        let url = folder.appending(path: name)
        try data.write(to: url)
        return url
    }

    @Test func otherAllowedImageFormatsAreImages() throws {
        for (type, name) in [("public.jpeg", "a.jpg"), ("com.compuserve.gif", "b.gif"), ("public.tiff", "c.tiff")] {
            let url = try write(try CraftedPNG.encoded(width: 40, height: 30, as: type), named: name)
            #expect(maker.mediaKind(of: url) == .image, "\(name)")
        }
    }

    @Test func typesThatCanLoadOtherResourcesAreSkipped() throws {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg"><image href="https://example.com/a.png"/></svg>"#
        #expect(maker.mediaKind(of: try write(Data(svg.utf8), named: "remote.svg")) == nil)
        let pdf = Data("%PDF-1.4\n%%EOF\n".utf8)
        #expect(maker.mediaKind(of: try write(pdf, named: "document.pdf")) == nil)
        let jpeg2000 = try CraftedPNG.encoded(width: 40, height: 30, as: "public.jpeg-2000")
        #expect(maker.mediaKind(of: try write(jpeg2000, named: "picture.jp2")) == nil)
    }

    @Test func imageWhoseBytesAreAnotherFormatIsSkipped() throws {
        let jpeg = try CraftedPNG.encoded(width: 40, height: 30, as: "public.jpeg")
        #expect(maker.mediaKind(of: try write(jpeg, named: "not-really.png")) == nil)
        let gif = try CraftedPNG.encoded(width: 40, height: 30, as: "com.compuserve.gif")
        #expect(maker.mediaKind(of: try write(gif, named: "not-really.jpg")) == nil)
    }

    @Test func imageOverThePixelLimitIsSkipped() throws {
        let under = try write(try CraftedPNG.blank(width: 10900, height: 10900), named: "under.png")
        #expect(maker.mediaKind(of: under) == .image)
        let over = try write(try CraftedPNG.blank(width: 11000, height: 11000), named: "over.png")
        #expect(maker.mediaKind(of: over) == nil)
        let bomb = try write(CraftedPNG.headerOnly(width: 60000, height: 60000), named: "bomb.png")
        #expect(maker.mediaKind(of: bomb) == nil)
    }

    @Test func referenceMoviesAndMoviesWithoutMediaAreSkipped() throws {
        #expect(maker.mediaKind(of: try write(MovieBoxes.reference, named: "reference.mov")) == nil)
        #expect(maker.mediaKind(of: try write(MovieBoxes.reference, named: "reference.mp4")) == nil)
        #expect(maker.mediaKind(of: try write(Data(), named: "empty.m4v")) == nil)
        #expect(maker.mediaKind(of: try write(Data("not a movie".utf8), named: "text.mov")) == nil)
        // The policy accepts the structure of a movie that holds its media, even a made-up one.
        #expect(maker.mediaKind(of: try write(MovieBoxes.selfContained, named: "made-up.mov")) == .movie)
    }

    @Test func cancellingReturnsAtOnce() async throws {
        let url = try writePNG(named: "cancelled.png", width: 4000, height: 3000)
        let task = Task { await maker.thumbnail(of: url, maximumPixelSize: 256) }
        task.cancel()
        // Either QuickLook already answered or the cancel did; it must not hang.
        _ = await task.value
    }

    @Test func largeImagesAreScaledDownWhenEncoded() throws {
        let thumbnail = try #require(
            QuickLookFileThumbnailMaker.encode(try image(width: 1000, height: 500), maximumPixelSize: 256))
        #expect(thumbnail.pixelWidth == 256)
        #expect(thumbnail.pixelHeight == 128)
        try expectPNG(thumbnail, longerSide: 256)
    }

    @Test func ingestorStoresTheThumbnailsOfRealFiles() async throws {
        let photo = try writePNG(named: "a.png", width: 300, height: 300)
        let movie = try await writeMovie(named: "b.mov", width: 320, height: 240)
        let blobs = InMemoryBlobStore()
        let ingestor = FileThumbnailIngestor(maker: maker)
        let result = await ingestor.ingest(
            [FileReference(url: photo), FileReference(url: movie)],
            reservation: InFlightBlobStore(base: blobs).reservation())
        #expect(result.map(\.thumbnail?.kind) == [.image, .movie])
        #expect(blobs.allIDs().count == 2)
        // Only thumbnails are kept, never the files' data.
        let movieData = FileManager.default.contents(atPath: movie.path(percentEncoded: false))
        for id in blobs.allIDs() {
            let stored = try blobs.read(id)
            #expect(stored.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
            #expect(stored != movieData)
        }
    }
}
