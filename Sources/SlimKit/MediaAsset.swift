import Foundation
import Photos

struct MediaAsset: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case photo
        case video
    }

    let id: String
    let kind: Kind
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: TimeInterval?
    let isFavorite: Bool
    let eligibility: MediaEligibility

    init(asset: PHAsset) {
        id = asset.localIdentifier
        kind = asset.mediaType == .video ? .video : .photo
        creationDate = asset.creationDate
        pixelWidth = asset.pixelWidth
        pixelHeight = asset.pixelHeight
        duration = asset.mediaType == .video ? asset.duration : nil
        isFavorite = asset.isFavorite
        eligibility = .pendingInspection
    }
}

enum PhotosAccessState: Equatable {
    case notDetermined
    case authorized
    case limited
    case denied
    case restricted

    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .notDetermined:
            self = .notDetermined
        case .authorized:
            self = .authorized
        case .limited:
            self = .limited
        case .denied:
            self = .denied
        case .restricted:
            self = .restricted
        @unknown default:
            self = .restricted
        }
    }

    var canRead: Bool {
        self == .authorized || self == .limited
    }
}
