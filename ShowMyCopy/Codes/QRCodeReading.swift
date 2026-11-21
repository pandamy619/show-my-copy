import Foundation

/// Finds the text of the QR codes in an image. `VisionQRCodeReader` is the app's implementation, on this Mac only;
/// tests use a fake.
protocol QRCodeReading: Sendable {
    /// The payloads of the QR codes in `data`, image data copied as `typeIdentifier`, in the order found. Empty
    /// when there is none or the data is not an image the app decodes. Runs off the caller's actor.
    func payloads(inImageData data: Data, typeIdentifier: String) async -> [String]
}
