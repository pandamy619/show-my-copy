import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Reads QR codes with the Vision framework, which runs on the device: nothing is sent anywhere.
///
/// The image is opened through `CheckedImageSource`, so only an allowed format within the pixel limit is decoded, and
/// decoded at most at `maximumPixelSize` on its longer side, enough for a QR code in a phone screenshot.
struct VisionQRCodeReader: QRCodeReading {
    static let maximumPixelSize = 3000

    func payloads(inImageData data: Data, typeIdentifier: String) async -> [String] {
        guard let image = Self.decode(data, typeIdentifier: typeIdentifier) else {
            return []
        }
        var request = DetectBarcodesRequest()
        request.symbologies = [.qr]
        do {
            return try await request.perform(on: image).compactMap(\.payloadString)
        } catch {
            AppLogger.app.error("Could not look for QR codes in the copied image")
            return []
        }
    }

    private static func decode(_ data: Data, typeIdentifier: String) -> CGImage? {
        guard let checked = CheckedImageSource.open(data, declaredType: typeIdentifier), checked.isWithinPixelLimit
        else {
            return nil
        }
        let options =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(checked.source, 0, options)
    }
}
