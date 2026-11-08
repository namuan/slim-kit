import Foundation
import Photos
import UniformTypeIdentifiers

struct PhotoKitResourceCandidate {
    let selection: PhotoResourceCandidate
    let transfer: (FileHandle, URL, Bool) async throws -> Int64
}

enum PhotoKitAssetKind {
    case photo
    case video
    case other
}

struct PhotoKitAssetSnapshot {
    let assetIdentifier: String
    let kind: PhotoKitAssetKind
    let mediaSubtypeRawValue: UInt
    let modificationDate: Date?
    let resources: [PhotoKitResourceCandidate]
}

protocol PhotoKitResourceCatalog {
    var canReadPhotos: Bool { get }

    func snapshot(assetIdentifier: String) -> PhotoKitAssetSnapshot?
}

struct PhotoKitResourceSource: ResourceExportSource {
    private let catalog: any PhotoKitResourceCatalog

    init(catalog: any PhotoKitResourceCatalog = LivePhotoKitResourceCatalog()) {
        self.catalog = catalog
    }

    var canReadPhotos: Bool {
        catalog.canReadPhotos
    }

    func selectResource(assetIdentifier: String) throws -> SelectedResource {
        guard catalog.canReadPhotos else { throw ResourceExportError.accessUnavailable }
        guard let snapshot = catalog.snapshot(assetIdentifier: assetIdentifier),
              snapshot.assetIdentifier == assetIdentifier else {
            throw ResourceExportError.assetUnavailable
        }
        guard let kind = mediaAssetKind(for: snapshot.kind) else {
            throw ResourceExportError.unsupported("Only photos and videos are supported.")
        }
        let selection = try PhotoResourceSelector.select(
            kind: kind,
            mediaSubtypeRawValue: snapshot.mediaSubtypeRawValue,
            resources: snapshot.resources.map(\.selection)
        )
        guard let resource = snapshot.resources.first else {
            throw ResourceExportError.unsupported("The item does not have one unambiguous original resource.")
        }
        guard let modificationDate = snapshot.modificationDate else {
            throw ResourceExportError.sourceStateUnavailable
        }
        let identity = ResourceExportSourceIdentity(
            assetIdentifier: assetIdentifier,
            modificationDate: modificationDate,
            resourceSelectionBasis: selection.resourceSelectionBasis
        )
        let fileExtension = UTType(selection.uniformTypeIdentifier)?.preferredFilenameExtension
        let filename = fileExtension.map { "source-resource.\($0)" } ?? "source-resource"
        return SelectedResource(
            sourceModificationDate: modificationDate,
            kind: selection.kind,
            basis: selection.resourceSelectionBasis,
            filename: filename,
            transfer: resource.transfer,
            verifySource: { try verifySource(identity) }
        )
    }

    private func verifySource(_ expectedIdentity: ResourceExportSourceIdentity) throws {
        guard catalog.canReadPhotos,
              let snapshot = catalog.snapshot(assetIdentifier: expectedIdentity.assetIdentifier),
              snapshot.assetIdentifier == expectedIdentity.assetIdentifier,
              snapshot.modificationDate == expectedIdentity.modificationDate,
              let kind = mediaAssetKind(for: snapshot.kind) else {
            throw ResourceExportError.sourceChanged
        }
        let currentSelection: PhotoResourceSelection
        do {
            currentSelection = try PhotoResourceSelector.select(
                kind: kind,
                mediaSubtypeRawValue: snapshot.mediaSubtypeRawValue,
                resources: snapshot.resources.map(\.selection)
            )
        } catch {
            throw ResourceExportError.sourceChanged
        }
        guard expectedIdentity.matches(
            assetIdentifier: snapshot.assetIdentifier,
            modificationDate: snapshot.modificationDate,
            resourceSelectionBasis: currentSelection.resourceSelectionBasis
        ) else {
            throw ResourceExportError.sourceChanged
        }
    }

    private func mediaAssetKind(for kind: PhotoKitAssetKind) -> MediaAsset.Kind? {
        switch kind {
        case .photo:
            .photo
        case .video:
            .video
        case .other:
            nil
        }
    }
}

struct LivePhotoKitResourceCatalog: PhotoKitResourceCatalog {
    var canReadPhotos: Bool {
        guard !PhotosRuntimeEnvironment.isRunningTests else { return false }
        return PhotosAccessState(PHPhotoLibrary.authorizationStatus(for: .readWrite)).canRead
    }

    func snapshot(assetIdentifier: String) -> PhotoKitAssetSnapshot? {
        guard !PhotosRuntimeEnvironment.isRunningTests,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil).firstObject else {
            return nil
        }
        let kind: PhotoKitAssetKind
        switch asset.mediaType {
        case .image:
            kind = .photo
        case .video:
            kind = .video
        default:
            kind = .other
        }
        let resources = PHAssetResource.assetResources(for: asset).map { resource in
            PhotoKitResourceCandidate(
                selection: PhotoResourceCandidate(
                    typeRawValue: resource.type.rawValue,
                    kind: MediaEligibilityClassifier.resourceKind(resource.type),
                    uniformTypeIdentifier: resource.uniformTypeIdentifier
                ),
                transfer: { fileHandle, resourceURL, networkAccessAllowed in
                    try await PhotoResourceExporter.transfer(
                        resource,
                        to: fileHandle,
                        at: resourceURL,
                        networkAccessAllowed: networkAccessAllowed
                    )
                }
            )
        }
        return PhotoKitAssetSnapshot(
            assetIdentifier: asset.localIdentifier,
            kind: kind,
            mediaSubtypeRawValue: asset.mediaSubtypes.rawValue,
            modificationDate: asset.modificationDate,
            resources: resources
        )
    }
}
