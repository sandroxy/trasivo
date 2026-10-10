import Foundation
import Trasivo

/// A correctly named local resource that stays alive until Photos finishes importing it.
final class PhotoLibraryResourceFile {
    let url: URL
    private let directory: URL

    init(source: URL, type: String) throws {
        guard source.isFileURL,
              let suffix = PhotoLibraryResourceType.filenameExtension(for: type), !suffix.isEmpty,
              try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw TransferFailure("destination_failed")
        }
        // A sibling directory keeps the link on the source volume. Download sources
        // are app-owned temporary files; do not copy large videos or rename the source.
        directory = source.deletingLastPathComponent().appendingPathComponent("trasivo-photos-\(UUID().uuidString)", isDirectory: true)
        url = directory.appendingPathComponent("resource").appendingPathExtension(suffix)
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
        do { try files.linkItem(at: source, to: url) }
        catch { try? files.removeItem(at: directory); throw error }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
    deinit { remove() }
}
