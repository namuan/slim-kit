import Foundation
import Photos
import UniformTypeIdentifiers

struct PhotoResourceExporter {
    static func measure(
        assetIdentifier: String,
        networkAccessAllowed: Bool = false,
        source: any ResourceExportSource = PhotoKitResourceSource(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) async throws -> VerifiedResourceMeasurement {
        guard source.canReadPhotos else { throw ResourceExportError.accessUnavailable }
        let selectedResource = try source.selectResource(assetIdentifier: assetIdentifier)
        try Task.checkCancellation()
        let exportedResource = try await exportResource(
            selectedResource,
            networkAccessAllowed: networkAccessAllowed,
            temporaryDirectory: temporaryDirectory
        )
        try Task.checkCancellation()
        try selectedResource.verifySource()
        AppLogger.shared.info(
            "ResourceExport",
            "Verified selected resource; kind=\(selectedResource.kind); bytes=\(exportedResource.byteCount); " +
                "networkAccess=\(networkAccessAllowed); capabilities=\(exportedResource.capabilities.logLabel)"
        )
        return VerifiedResourceMeasurement(
            size: VerifiedResourceSize(
                assetID: assetIdentifier,
                byteCount: exportedResource.byteCount,
                sourceModificationDate: selectedResource.sourceModificationDate,
                resourceSelectionBasis: selectedResource.basis,
                measuredAt: .now
            ),
            capabilities: exportedResource.capabilities
        )
    }

    private static func exportResource(
        _ selectedResource: SelectedResource,
        networkAccessAllowed: Bool,
        temporaryDirectory: URL
    ) async throws -> ExportedResource {
        return try await ResourceExportWorkspace.withTemporaryResource(
            in: temporaryDirectory,
            filename: selectedResource.filename
        ) { resourceURL in
            let fileHandle: FileHandle
            do {
                fileHandle = try FileHandle(forWritingTo: resourceURL)
            } catch {
                throw ResourceExportError.exportFailed
            }
            defer { try? fileHandle.close() }
            let byteCount = try await selectedResource.transfer(
                fileHandle,
                resourceURL,
                networkAccessAllowed
            )
            try fileHandle.close()
            let capabilities: MediaCapabilityDecision
            switch selectedResource.kind {
            case .photo:
                capabilities = MediaCapabilityInspector.inspectImage(at: resourceURL)
            case .video:
                capabilities = await MediaCapabilityInspector.inspectVideo(at: resourceURL)
            }
            return ExportedResource(byteCount: byteCount, capabilities: capabilities)
        }
    }

    static func transfer(
        _ resource: PHAssetResource,
        to fileHandle: FileHandle,
        at resourceURL: URL,
        networkAccessAllowed: Bool
    ) async throws -> Int64 {
        let manager = PHAssetResourceManager.default()
        let operation = ResourceExportOperation(fileHandle: fileHandle) {
            manager.cancelDataRequest($0)
        }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = networkAccessAllowed
        let progressLogger = ResourceExportProgressLogger()
        options.progressHandler = { progressLogger.record($0) }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    operation.setContinuation(continuation)
                    let requestID = manager.requestData(
                        for: resource,
                        options: options,
                        dataReceivedHandler: { operation.receive($0) },
                        completionHandler: { operation.finish(error: $0) }
                    )
                    operation.install(requestID: requestID)
                }
            } onCancel: {
                operation.cancel()
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let error = error as? ResourceExportError { throw error }
            throw ResourceExportError.exportFailed
        }
        try Task.checkCancellation()
        try fileHandle.synchronize()
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: resourceURL.path)
        guard let fileByteCount = (fileAttributes[.size] as? NSNumber)?.int64Value else {
            throw ResourceExportError.exportFailed
        }
        return try operation.verifiedByteCount(fileByteCount: fileByteCount)
    }

    static func verifySource(expectedIdentity: ResourceExportSourceIdentity) throws {
        guard canReadPhotos,
              let currentAsset = fetchAsset(expectedIdentity.assetIdentifier),
              currentAsset.modificationDate == expectedIdentity.modificationDate else {
            throw ResourceExportError.sourceChanged
        }
        let currentResource: PhotoKitSelectedResource
        do {
            currentResource = try selectResource(for: currentAsset)
        } catch {
            throw ResourceExportError.sourceChanged
        }
        guard expectedIdentity.matches(
            assetIdentifier: currentAsset.localIdentifier,
            modificationDate: currentAsset.modificationDate,
            resourceSelectionBasis: currentResource.basis
        ) else {
            throw ResourceExportError.sourceChanged
        }
    }

    static var canReadPhotos: Bool {
        PhotosAccessState(PHPhotoLibrary.authorizationStatus(for: .readWrite)).canRead
    }

    static func fetchAsset(_ identifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
    }

    static func selectResource(for asset: PHAsset) throws -> PhotoKitSelectedResource {
        let kind: MediaAsset.Kind
        switch asset.mediaType {
        case .image:
            kind = .photo
        case .video:
            kind = .video
        default:
            throw ResourceExportError.unsupported("Only photos and videos are supported.")
        }
        let resources = PHAssetResource.assetResources(for: asset)
        let candidates = resources.map { resource in
            PhotoResourceCandidate(
                typeRawValue: resource.type.rawValue,
                kind: MediaEligibilityClassifier.resourceKind(resource.type),
                uniformTypeIdentifier: resource.uniformTypeIdentifier
            )
        }
        let selection = try PhotoResourceSelector.select(
            kind: kind,
            mediaSubtypeRawValue: asset.mediaSubtypes.rawValue,
            resources: candidates
        )
        guard let resource = resources.first else {
            throw ResourceExportError.unsupported("The item does not have one unambiguous original resource.")
        }
        return PhotoKitSelectedResource(
            resource: resource,
            kind: selection.kind,
            basis: selection.resourceSelectionBasis
        )
    }
}

enum ResourceExportWorkspace {
    static func withTemporaryResource<Value>(
        in temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        filename: String,
        operation: (URL) async throws -> Value
    ) async throws -> Value {
        let fileManager = FileManager.default
        let workspace = temporaryDirectory
            .appendingPathComponent("SlimKit-Resource-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: workspace) }
        let resourceURL = workspace.appendingPathComponent(filename)
        guard fileManager.createFile(atPath: resourceURL.path, contents: nil) else {
            throw ResourceExportError.exportFailed
        }
        return try await operation(resourceURL)
    }
}

private struct ExportedResource {
    let byteCount: Int64
    let capabilities: MediaCapabilityDecision
}

protocol ResourceExportSource {
    var canReadPhotos: Bool { get }

    func selectResource(assetIdentifier: String) throws -> SelectedResource
}

struct SelectedResource {
    let sourceModificationDate: Date
    let kind: MediaAsset.Kind
    let basis: String
    let filename: String
    let transfer: (FileHandle, URL, Bool) async throws -> Int64
    let verifySource: () throws -> Void
}

struct PhotoKitSelectedResource {
    let resource: PHAssetResource
    let kind: MediaAsset.Kind
    let basis: String
}

struct PhotoKitResourceSource: ResourceExportSource {
    var canReadPhotos: Bool {
        PhotoResourceExporter.canReadPhotos
    }

    func selectResource(assetIdentifier: String) throws -> SelectedResource {
        guard canReadPhotos else { throw ResourceExportError.accessUnavailable }
        guard let asset = PhotoResourceExporter.fetchAsset(assetIdentifier) else {
            throw ResourceExportError.assetUnavailable
        }
        let photoKitResource = try PhotoResourceExporter.selectResource(for: asset)
        guard let sourceModificationDate = asset.modificationDate else {
            throw ResourceExportError.sourceStateUnavailable
        }
        let identity = ResourceExportSourceIdentity(
            assetIdentifier: assetIdentifier,
            modificationDate: sourceModificationDate,
            resourceSelectionBasis: photoKitResource.basis
        )
        let fileExtension = UTType(photoKitResource.resource.uniformTypeIdentifier)?.preferredFilenameExtension
        let filename = fileExtension.map { "source-resource.\($0)" } ?? "source-resource"
        return SelectedResource(
            sourceModificationDate: sourceModificationDate,
            kind: photoKitResource.kind,
            basis: photoKitResource.basis,
            filename: filename,
            transfer: { fileHandle, resourceURL, networkAccessAllowed in
                try await PhotoResourceExporter.transfer(
                    photoKitResource.resource,
                    to: fileHandle,
                    at: resourceURL,
                    networkAccessAllowed: networkAccessAllowed
                )
            },
            verifySource: {
                try PhotoResourceExporter.verifySource(expectedIdentity: identity)
            }
        )
    }
}

final class ResourceExportOperation: @unchecked Sendable {
    private let cancelRequest: @Sendable (PHAssetResourceDataRequestID) -> Void
    private let fileHandle: FileHandle
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var requestID: PHAssetResourceDataRequestID?
    private var cancellationRequested = false
    private var finished = false
    private var writeError: Error?
    private var byteCounter = ResourceByteCounter()

    init(
        fileHandle: FileHandle,
        cancelRequest: @escaping @Sendable (PHAssetResourceDataRequestID) -> Void
    ) {
        self.fileHandle = fileHandle
        self.cancelRequest = cancelRequest
    }

    func setContinuation(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func install(requestID: PHAssetResourceDataRequestID) {
        lock.lock()
        self.requestID = requestID
        let shouldCancel = cancellationRequested || writeError != nil
        lock.unlock()
        if shouldCancel { cancelRequest(requestID) }
    }

    func receive(_ data: Data) {
        lock.lock()
        guard !finished, writeError == nil else {
            lock.unlock()
            return
        }
        do {
            try fileHandle.write(contentsOf: data)
            try byteCounter.append(data.count)
            lock.unlock()
        } catch {
            writeError = error
            let requestID = self.requestID
            lock.unlock()
            if let requestID { cancelRequest(requestID) }
            finish(error: error)
        }
    }

    func finish(error: Error?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let result: Result<Void, Error>
        if let writeError {
            result = .failure(writeError)
        } else if let error {
            result = .failure(error)
        } else {
            result = .success(())
        }
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let requestID = self.requestID
        lock.unlock()
        if let requestID { cancelRequest(requestID) }
        finish(error: CancellationError())
    }

    func verifiedByteCount(fileByteCount: Int64) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return try byteCounter.verifiedByteCount(fileByteCount: fileByteCount)
    }
}

private final class ResourceExportProgressLogger: @unchecked Sendable {
    private let lock = NSLock()
    private var lastLoggedProgress = 0.0

    func record(_ progress: Double) {
        lock.lock()
        let shouldLog = progress >= 1 || progress - lastLoggedProgress >= 0.1
        if shouldLog { lastLoggedProgress = progress }
        lock.unlock()
        if shouldLog {
            AppLogger.shared.debug("ResourceExport", "Resource transfer progress=\(Int(progress * 100))%")
        }
    }
}
