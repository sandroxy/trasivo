#if os(iOS)
import Foundation
import Photos
import Trasivo
import os.log

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
    private static let log = OSLog(subsystem: "io.github.sandroxy.trasivo", category: "Photos")
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
        let type: String?
        switch media {
        case .image: type = PhotoLibraryResourceType.image(at: temporaryFile)
        case .video: type = PhotoLibraryResourceType.video(filename: filename)
        }
        guard let type = type else {
            os_log("Cannot determine a supported Photos resource type", log: Self.log, type: .error)
            completion(.failure(TransferFailure("destination_failed"))); return
        }
        let resource: PhotoLibraryResourceFile
        do { resource = try PhotoLibraryResourceFile(source: temporaryFile, type: type) }
        catch {
            let error = error as NSError
            os_log("Photos resource preparation failed: %{public}@ (%{public}ld)", log: Self.log, type: .error, error.domain, error.code)
            completion(.failure(TransferFailure("destination_failed"))); return
        }
        var identifier: String?
        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = filename
            options.uniformTypeIdentifier = type
            // Photos rejects unknown URL extensions even with an explicit type.
            // It must copy this hard link: moving a hard-linked resource is unsupported.
            options.shouldMoveFile = false
            request.addResource(with: media == .image ? .photo : .video, fileURL: resource.url, options: options)
            identifier = request.placeholderForCreatedAsset?.localIdentifier
        } completionHandler: { success, error in
            defer { resource.remove() }
            if success, let identifier = identifier { completion(.success(["assetIdentifier": identifier])) }
            else {
                if let error = error as NSError? {
                    // Keep native diagnostics without logging paths, filenames, or userInfo.
                    os_log("Photos save failed: %{public}@ (%{public}ld)", log: Self.log, type: .error, error.domain, error.code)
                } else {
                    os_log("Photos did not return a committed asset identifier", log: Self.log, type: .error)
                }
                completion(.failure(TransferFailure("destination_failed")))
            }
        }
    }
}
#endif
