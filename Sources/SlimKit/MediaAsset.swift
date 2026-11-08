import Foundation
import Photos

struct MediaAsset: Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case photo
        case video
    }

    let id: String
    let kind: Kind
    let creationDate: Date?
    let modificationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: TimeInterval?
    let isFavorite: Bool
    var eligibility: MediaEligibility

    init(asset: PHAsset) {
        self.init(
            id: asset.localIdentifier,
            kind: asset.mediaType == .video ? .video : .photo,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            duration: asset.mediaType == .video ? asset.duration : nil,
            isFavorite: asset.isFavorite,
            eligibility: .pendingInspection
        )
    }

    init(
        id: String,
        kind: Kind,
        creationDate: Date?,
        modificationDate: Date?,
        pixelWidth: Int,
        pixelHeight: Int,
        duration: TimeInterval?,
        isFavorite: Bool,
        eligibility: MediaEligibility
    ) {
        self.id = id
        self.kind = kind
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.isFavorite = isFavorite
        self.eligibility = eligibility
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
