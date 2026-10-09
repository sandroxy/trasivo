#if os(iOS)
import Foundation
import Photos
import Trasivo

public enum PhotoLibraryAccess {
    public static func request(_ completion: @escaping (Bool) -> Void) {
        guard Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") != nil else { completion(false); return }
        if #available(iOS 14, *) {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { completion($0 == .authorized || $0 == .limited) }
        } else {
            guard Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") != nil else { completion(false); return }
            PHPhotoLibrary.requestAuthorization { completion($0 == .authorized) }
        }
    }
}

public struct PhotoLibraryDestination: DownloadDestination {
    public enum Media { case image, video }
    public let media: Media
    public let filename: String
    public init(media: Media, filename: String) throws {
        guard !filename.isEmpty, !filename.contains("/"), !filename.contains("\\") else { throw TransferFailure("invalid_filename") }
        self.media = media; self.filename = filename
    }
    public func save(_ temporaryFile: URL, completion: @escaping (Result<[String: String], TransferFailure>) -> Void) {
        let allowed: Bool
        if #available(iOS 14, *) {
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            allowed = status == .authorized || status == .limited
        } else { allowed = PHPhotoLibrary.authorizationStatus() == .authorized }
        guard allowed else { completion(.failure(TransferFailure("photo_permission_required"))); return }
        var identifier: String?
        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = filename
            request.addResource(with: media == .image ? .photo : .video, fileURL: temporaryFile, options: options)
            identifier = request.placeholderForCreatedAsset?.localIdentifier
        } completionHandler: { success, _ in
            if success, let identifier = identifier { completion(.success(["assetIdentifier": identifier])) }
            else { completion(.failure(TransferFailure("destination_failed"))) }
        }
    }
}
#endif
