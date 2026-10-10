import Foundation
import ImageIO
import UniformTypeIdentifiers
#if os(iOS)
import MobileCoreServices
#elseif os(macOS)
import CoreServices
#endif

/// Resolve Photos resource types without relying on the download's temporary suffix.
enum PhotoLibraryResourceType {
    static func image(at file: URL) -> String? {
        guard file.isFileURL,
              let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) else { return nil }
        return type as String
    }

    /// Video container metadata is supplied by the host; Photos validates the resource itself.
    static func video(filename: String) -> String? {
        let suffix = (filename as NSString).pathExtension
        guard !suffix.isEmpty else { return nil }
        if #available(iOS 14, macOS 11, *) {
            guard let type = UTType(filenameExtension: suffix), type.conforms(to: .movie) else { return nil }
            return type.identifier
        } else {
            guard let type = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, suffix as CFString, nil)?.takeRetainedValue(),
                  UTTypeConformsTo(type, kUTTypeMovie) else { return nil }
            return type as String
        }
    }

    static func filenameExtension(for identifier: String) -> String? {
        if #available(iOS 14, macOS 11, *) {
            return UTType(identifier)?.preferredFilenameExtension
        } else {
            return UTTypeCopyPreferredTagWithClass(identifier as CFString, kUTTagClassFilenameExtension)?.takeRetainedValue() as String?
        }
    }
}
