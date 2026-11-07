import Photos

struct MediaResourceDescriptor: Equatable, Sendable {
    enum Kind: String, Sendable {
        case photo
        case video
        case pairedVideo
        case adjustment
        case auxiliary
        case other
    }

    let kind: Kind
}

enum MediaEligibility: Equatable, Hashable, Sendable {
    case pendingInspection
    case inspectImageSource
    case inspectVideoSource
    case unsupported(String)
    case unavailable(String)

    var isUnsupported: Bool {
        if case .unsupported = self { return true }
        return false
    }
}

enum MediaEligibilityClassifier {
    static func classify(
        kind: MediaAsset.Kind,
        mediaSubtypeRawValue: UInt,
        resources: [MediaResourceDescriptor]
    ) -> MediaEligibility {
        guard mediaSubtypeRawValue == 0 else {
            return .unsupported("Special media subtypes are not supported in the MVP.")
        }

        switch kind {
        case .photo:
            guard resources.count == 1, resources.first?.kind == .photo else {
                return .unsupported("The photo has paired, edited, auxiliary, or ambiguous resources.")
            }
            return .inspectImageSource
        case .video:
            guard resources.count == 1, resources.first?.kind == .video else {
                return .unsupported("The video has edited, additional, or ambiguous resources.")
            }
            return .inspectVideoSource
        }
    }

    static func classify(asset: PHAsset) -> MediaEligibility {
        let kind: MediaAsset.Kind
        switch asset.mediaType {
        case .image:
            kind = .photo
        case .video:
            kind = .video
        default:
            return .unsupported("Only photos and videos are supported.")
        }

        let descriptors = PHAssetResource.assetResources(for: asset).map { resource in
            MediaResourceDescriptor(kind: resourceKind(resource.type))
        }
        return classify(kind: kind, mediaSubtypeRawValue: asset.mediaSubtypes.rawValue, resources: descriptors)
    }

    private static func resourceKind(_ type: PHAssetResourceType) -> MediaResourceDescriptor.Kind {
        switch type {
        case .photo:
            .photo
        case .video:
            .video
        case .pairedVideo, .fullSizePairedVideo, .adjustmentBasePairedVideo:
            .pairedVideo
        case .adjustmentData, .adjustmentBasePhoto, .adjustmentBaseVideo, .fullSizePhoto, .fullSizeVideo:
            .adjustment
        case .photoProxy, .audio, .alternatePhoto:
            .auxiliary
        @unknown default:
            .other
        }
    }
}
