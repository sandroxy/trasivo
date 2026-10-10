import XCTest
import ImageIO
@testable import TrasivoStorage

final class PhotoLibraryResourceTypeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory = directory { try FileManager.default.removeItem(at: directory) }
    }

    private func image(type: String, filename: String, frames: Int = 1) throws -> URL {
        let url = directory.appendingPathComponent(filename)
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, frames, nil))
        for frame in 0..<frames {
            // Distinct frames keep the GIF encoder from coalescing identical images.
            context.setFillColor(CGColor(red: CGFloat(frame % 2), green: 1, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            let image = try XCTUnwrap(context.makeImage())
            let properties = type == "com.compuserve.gif"
                ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary : nil
            CGImageDestinationAddImage(destination, image, properties)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testJPEGDownloadIsIdentifiedDespitePartSuffix() throws {
        let url = try image(type: "public.jpeg", filename: "download.part")
        XCTAssertEqual(PhotoLibraryResourceType.image(at: url), "public.jpeg")
    }

    func testImageContentsTakePrecedenceOverMisleadingFilename() throws {
        let url = try image(type: "public.png", filename: "image.jpg")
        XCTAssertEqual(PhotoLibraryResourceType.image(at: url), "public.png")
    }

    func testAnimatedImageIsInspectedWithoutRewritingItsBytes() throws {
        let url = try image(type: "com.compuserve.gif", filename: "download.part", frames: 2)
        let before = try Data(contentsOf: url)
        XCTAssertEqual(PhotoLibraryResourceType.image(at: url), "com.compuserve.gif")
        XCTAssertEqual(try Data(contentsOf: url), before)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
    }

    func testNonImageResponseIsRejectedDespiteJPEGFilename() throws {
        let url = directory.appendingPathComponent("image.jpg")
        try Data("<html>not an image</html>".utf8).write(to: url)
        XCTAssertNil(PhotoLibraryResourceType.image(at: url))
    }

    func testVideoTypesUseTheHostFilename() {
        XCTAssertEqual(PhotoLibraryResourceType.video(filename: "video.mp4"), "public.mpeg-4")
        XCTAssertEqual(PhotoLibraryResourceType.video(filename: "video.MOV"), "com.apple.quicktime-movie")
        XCTAssertEqual(PhotoLibraryResourceType.video(filename: "video.m4v"), "com.apple.m4v-video")
    }

    func testVideoDoesNotGuessATypeForMissingOrNonVideoExtensions() {
        for filename in ["video", "download.part", "image.jpg", "audio.mp3", "video.trasivo-unknown"] {
            XCTAssertNil(PhotoLibraryResourceType.video(filename: filename), filename)
        }
    }
}
