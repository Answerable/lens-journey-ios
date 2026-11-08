import Foundation

public struct PreparedImage: Equatable, Sendable {
    public let data: Data; public let mimeType: String
    public init(data: Data, mimeType: String) { self.data = data; self.mimeType = mimeType }
}
public protocol ImagePreparer: Sendable { func prepare(_ image: Data) throws -> PreparedImage }

#if canImport(ImageIO) && canImport(CoreGraphics)
import ImageIO
import CoreGraphics

public struct ImageIOPreparer: ImagePreparer {
    public init() {}
    public func prepare(_ image: Data) throws -> PreparedImage {
        guard let source = CGImageSourceCreateWithData(image as CFData, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else {
            throw LensJourneyError(kind: .invalidImage, code: "INVALID_IMAGE", message: "Data is not a supported image")
        }
        let scale = min(1, 2048 / max(width, height)); let maxPixel = Int(max(width, height) * scale)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel, kCGImageSourceCreateThumbnailWithTransform: true]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw LensJourneyError(kind: .invalidImage, message: "Unable to decode image") }
        for quality in stride(from: 0.9, through: 0.3, by: -0.1) {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination), output.length < 4 * 1024 * 1024 { return PreparedImage(data: output as Data, mimeType: "image/jpeg") }
        }
        throw LensJourneyError(kind: .payloadTooLarge, code: "PAYLOAD_TOO_LARGE", message: "Image could not be compressed below 4 MB")
    }
}
#endif
