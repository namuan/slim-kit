import Foundation

struct PhotoResourceCandidate: Equatable, Sendable {
    let typeRawValue: Int
    let kind: MediaResourceDescriptor.Kind
    let uniformTypeIdentifier: String
}

struct PhotoResourceSelection: Equatable, Sendable {
    let kind: MediaAsset.Kind
    let resourceSelectionBasis: String
    let uniformTypeIdentifier: String
}

struct ResourceExportSourceIdentity: Equatable, Sendable {
    let assetIdentifier: String
    let modificationDate: Date
    let resourceSelectionBasis: String

    func matches(
        assetIdentifier: String,
        modificationDate: Date?,
        resourceSelectionBasis: String
    ) -> Bool {
        self.assetIdentifier == assetIdentifier
            && self.modificationDate == modificationDate
            && self.resourceSelectionBasis == resourceSelectionBasis
            && !resourceSelectionBasis.isEmpty
    }
}

enum PhotoResourceSelector {
    static func select(
        kind: MediaAsset.Kind,
        mediaSubtypeRawValue: UInt,
        resources: [PhotoResourceCandidate]
    ) throws -> PhotoResourceSelection {
        let descriptors = resources.map { MediaResourceDescriptor(kind: $0.kind) }
        let eligibility = MediaEligibilityClassifier.classify(
            kind: kind,
            mediaSubtypeRawValue: mediaSubtypeRawValue,
            resources: descriptors
        )
        let expectedKind: MediaResourceDescriptor.Kind
        switch eligibility {
        case .inspectImageSource:
            expectedKind = .photo
        case .inspectVideoSource:
            expectedKind = .video
        case let .unsupported(reason), let .unavailable(reason), let .uncertain(reason):
            throw ResourceExportError.unsupported(reason)
        case .pendingInspection, .capabilitiesInspected:
            throw ResourceExportError.unsupported("The Photos item has not been classified.")
        }
        guard resources.count == 1,
              let resource = resources.first,
              resource.kind == expectedKind else {
            throw ResourceExportError.unsupported("The item does not have one unambiguous original resource.")
        }
        let basis = "\(kind.rawValue)|\(resource.typeRawValue)|\(resource.uniformTypeIdentifier)"
        return PhotoResourceSelection(
            kind: kind,
            resourceSelectionBasis: basis,
            uniformTypeIdentifier: resource.uniformTypeIdentifier
        )
    }
}
