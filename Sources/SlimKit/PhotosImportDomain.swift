import CoreLocation
import Foundation
import Photos

struct ImportLocation: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let horizontalAccuracy: Double
    let verticalAccuracy: Double
    let timestamp: Date

    init(
        latitude: Double,
        longitude: Double,
        altitude: Double,
        horizontalAccuracy: Double,
        verticalAccuracy: Double,
        timestamp: Date
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.timestamp = timestamp
    }

    init(location: CLLocation) {
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        altitude = location.altitude
        horizontalAccuracy = location.horizontalAccuracy
        verticalAccuracy = location.verticalAccuracy
        timestamp = location.timestamp
    }

    var coreLocation: CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: altitude,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: verticalAccuracy,
            timestamp: timestamp
        )
    }

    func matches(_ other: ImportLocation) -> Bool {
        abs(latitude - other.latitude) <= 0.000_001 &&
            abs(longitude - other.longitude) <= 0.000_001 &&
            abs(altitude - other.altitude) <= 1 &&
            abs(horizontalAccuracy - other.horizontalAccuracy) <= 1 &&
            abs(verticalAccuracy - other.verticalAccuracy) <= 1 &&
            abs(timestamp.timeIntervalSince(other.timestamp)) <= 1
    }
}

struct CompressionImportMetadata: Codable, Equatable, Sendable {
    let creationDate: Date?
    let location: ImportLocation?
}

struct PhotosAssetSnapshot: Codable, Equatable, Sendable {
    let assetID: String
    let mediaKind: MediaAsset.Kind
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: Double?
    let creationDate: Date?
    let location: ImportLocation?
}

enum ImportVerificationState: Equatable, Sendable {
    case verified
    case pending(String)
    case failed(String)
    case needsReview(String)
}

struct CompressionImportResult: Equatable, Sendable {
    let operationID: String
    let replacementAssetID: String?
    let state: ImportVerificationState
}

enum PhotosImportError: LocalizedError, Equatable {
    case accessUnavailable
    case changeRequestFailed(String)
    case placeholderIdentifierUnavailable
    case assetUnavailable

    var errorDescription: String? {
        switch self {
        case .accessUnavailable: "Photos write access is unavailable."
        case let .changeRequestFailed(message): message
        case .placeholderIdentifierUnavailable: "Photos did not provide an identifier for the imported asset."
        case .assetUnavailable: "The imported Photos asset is not available yet."
        }
    }
}

@MainActor
protocol PhotosAssetImporting {
    var canReadAndWritePhotos: Bool { get }

    func importAsset(
        from outputURL: URL,
        mediaKind: MediaAsset.Kind,
        metadata: CompressionImportMetadata
    ) async throws -> String

    func snapshot(assetID: String) async throws -> PhotosAssetSnapshot?
}

@MainActor
protocol PhotosAssetDeleting {
    var canDeletePhotos: Bool { get }

    func deleteAsset(assetID: String) async throws
}

struct PhotoKitAssetImporter: PhotosAssetImporting, PhotosAssetDeleting {
    var canReadAndWritePhotos: Bool {
        guard !PhotosRuntimeEnvironment.isRunningTests else { return false }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    func importAsset(
        from outputURL: URL,
        mediaKind: MediaAsset.Kind,
        metadata: CompressionImportMetadata
    ) async throws -> String {
        guard canReadAndWritePhotos else { throw PhotosImportError.accessUnavailable }
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw PhotosImportError.changeRequestFailed("The compressed file is missing.")
        }
        let placeholder = PhotosImportPlaceholder()
        return try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                let request: PHAssetChangeRequest?
                switch mediaKind {
                case .photo:
                    request = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: outputURL)
                case .video:
                    request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputURL)
                }
                guard let request else {
                    placeholder.setFailure(
                        PhotosImportError.changeRequestFailed("Photos could not create the asset request.")
                    )
                    return
                }
                request.creationDate = metadata.creationDate
                request.location = metadata.location?.coreLocation
                placeholder.setIdentifier(request.placeholderForCreatedAsset?.localIdentifier)
            } completionHandler: { success, error in
                guard success else {
                    continuation.resume(
                        throwing: error.map { PhotosImportError.changeRequestFailed($0.localizedDescription) }
                            ?? PhotosImportError.changeRequestFailed("Photos rejected the import request.")
                    )
                    return
                }
                if let failure = placeholder.failure {
                    continuation.resume(throwing: failure)
                } else if let identifier = placeholder.identifier {
                    continuation.resume(returning: identifier)
                } else {
                    continuation.resume(throwing: PhotosImportError.placeholderIdentifierUnavailable)
                }
            }
        }
    }

    func snapshot(assetID: String) async throws -> PhotosAssetSnapshot? {
        guard canReadAndWritePhotos else { throw PhotosImportError.accessUnavailable }
        guard !PhotosRuntimeEnvironment.isRunningTests else { throw PhotosImportError.accessUnavailable }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else {
            return nil
        }
        let kind: MediaAsset.Kind
        switch asset.mediaType {
        case .image:
            kind = .photo
        case .video:
            kind = .video
        default:
            throw PhotosImportError.assetUnavailable
        }
        return PhotosAssetSnapshot(
            assetID: asset.localIdentifier,
            mediaKind: kind,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            duration: kind == .video ? asset.duration : nil,
            creationDate: asset.creationDate,
            location: asset.location.map(ImportLocation.init(location:))
        )
    }

    var canDeletePhotos: Bool {
        canReadAndWritePhotos
    }

    func deleteAsset(assetID: String) async throws {
        guard canDeletePhotos,
              !PhotosRuntimeEnvironment.isRunningTests,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else {
            throw PhotosImportError.accessUnavailable
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets([asset] as NSArray)
            } completionHandler: { success, error in
                guard success else {
                    continuation.resume(
                        throwing: error.map { PhotosImportError.changeRequestFailed($0.localizedDescription) }
                            ?? PhotosImportError.changeRequestFailed("Photos rejected the deletion request.")
                    )
                    return
                }
                continuation.resume()
            }
        }
    }
}

private final class PhotosImportPlaceholder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedIdentifier: String?
    private var storedFailure: PhotosImportError?

    var identifier: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedIdentifier
    }

    var failure: PhotosImportError? {
        lock.lock()
        defer { lock.unlock() }
        return storedFailure
    }

    func setIdentifier(_ identifier: String?) {
        lock.lock()
        storedIdentifier = identifier
        lock.unlock()
    }

    func setFailure(_ error: PhotosImportError) {
        lock.lock()
        storedFailure = error
        lock.unlock()
    }
}
