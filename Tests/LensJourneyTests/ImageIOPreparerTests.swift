#if canImport(ImageIO) && canImport(CoreGraphics)
import XCTest
import CoreGraphics
import ImageIO
@testable import LensJourney

final class ImageIOPreparerTests: XCTestCase {
    func testPreparerProducesJPEGWithinLimits() throws {
        let width = 32, height = 24
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let source = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(source, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let prepared = try ImageIOPreparer().prepare(source as Data)
        XCTAssertEqual(prepared.mimeType, "image/jpeg")
        XCTAssertLessThanOrEqual(prepared.data.count, 4 * 1024 * 1024)
        XCTAssertEqual(Array(prepared.data.prefix(3)), [0xff, 0xd8, 0xff])
    }
}
#endif
