import XCTest
@testable import TrasivoStorage

final class PhotoLibraryResourceFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory = directory { try FileManager.default.removeItem(at: directory) }
    }

    func testImportURLMatchesResourceTypeWithoutCopyingOrChangingSource() throws {
        let source = directory.appendingPathComponent("download.part")
        let bytes = Data([0, 1, 2, 3])
        try bytes.write(to: source)
        for (type, suffix) in [("public.jpeg", "jpeg"), ("public.png", "png"),
                               ("com.compuserve.gif", "gif"), ("public.mpeg-4", "mp4"),
                               ("com.apple.quicktime-movie", "mov")] {
            let resource = try PhotoLibraryResourceFile(source: source, type: type)
            XCTAssertEqual(resource.url.pathExtension, suffix)
            XCTAssertEqual(try Data(contentsOf: resource.url), bytes)
            let sourceInfo = try FileManager.default.attributesOfItem(atPath: source.path)
            let resourceInfo = try FileManager.default.attributesOfItem(atPath: resource.url.path)
            XCTAssertEqual(sourceInfo[.systemFileNumber] as? NSNumber, resourceInfo[.systemFileNumber] as? NSNumber)
            resource.remove()
            XCTAssertFalse(FileManager.default.fileExists(atPath: resource.url.deletingLastPathComponent().path))
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }

    func testConcurrentImportsKeepIndependentPathsAndLifetimes() throws {
        let source = directory.appendingPathComponent("download.part")
        try Data([0, 1, 2, 3]).write(to: source)
        var first: PhotoLibraryResourceFile? = try PhotoLibraryResourceFile(source: source, type: "public.jpeg")
        let second = try PhotoLibraryResourceFile(source: source, type: "public.jpeg")
        let firstURL = try XCTUnwrap(first?.url)
        XCTAssertNotEqual(firstURL, second.url)
        first = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        // Even if the owner releases its path, Photos can still finish using the link.
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: second.url), Data([0, 1, 2, 3]))
    }

    func testInvalidSourcesAndTypesLeaveNoStagingDirectories() throws {
        let source = directory.appendingPathComponent("download.part")
        try Data([0]).write(to: source)
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertThrowsError(try PhotoLibraryResourceFile(source: source, type: "io.github.sandroxy.unknown-resource"))
        XCTAssertThrowsError(try PhotoLibraryResourceFile(source: directory, type: "public.jpeg"))
        XCTAssertThrowsError(try PhotoLibraryResourceFile(source: directory.appendingPathComponent("missing.part"), type: "public.jpeg"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), before)
    }
}
