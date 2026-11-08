import Foundation

protocol DiskSpaceProviding {
    func availableBytes(at directory: URL) throws -> Int64
}

struct FileSystemDiskSpaceProvider: DiskSpaceProviding {
    func availableBytes(at directory: URL) throws -> Int64 {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        } catch {
            throw CompressionWorkspaceError.diskSpaceUnavailable
        }
        guard let availableBytes = (attributes[.systemFreeSize] as? NSNumber)?.int64Value,
              availableBytes >= 0 else {
            throw CompressionWorkspaceError.diskSpaceUnavailable
        }
        return availableBytes
    }
}

struct CompressionWorkspaceManager {
    let rootURL: URL
    let diskSpaceProvider: any DiskSpaceProviding

    init(rootURL: URL, diskSpaceProvider: any DiskSpaceProviding = FileSystemDiskSpaceProvider()) {
        self.rootURL = rootURL
        self.diskSpaceProvider = diskSpaceProvider
    }

    static func applicationSupport(
        diskSpaceProvider: any DiskSpaceProviding = FileSystemDiskSpaceProvider()
    ) throws -> CompressionWorkspaceManager {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CompressionWorkspaceError.workspaceCreationFailed
        }
        let rootURL = applicationSupport
            .appendingPathComponent("SlimKit", isDirectory: true)
            .appendingPathComponent("Jobs", isDirectory: true)
        return CompressionWorkspaceManager(rootURL: rootURL, diskSpaceProvider: diskSpaceProvider)
    }

    func retainArtifact(
        _ artifact: CompressedMediaArtifact,
        from workspace: CompressionWorkspace
    ) throws -> CompressedMediaArtifact {
        let sourceURL = artifact.outputURL.standardizedFileURL
        let workspaceOutputURL = workspace.outputDirectoryURL.standardizedFileURL
        guard sourceURL.path.hasPrefix(workspaceOutputURL.path + "/"),
              FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw CompressionArtifactRetentionError.invalidOutput
        }
        let artifactsURL = rootURL.appendingPathComponent("ReadyForImport", isDirectory: true)
        let artifactDirectoryURL = artifactsURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileExtension = sourceURL.pathExtension
        let retainedURL = artifactDirectoryURL
            .appendingPathComponent("compressed-output")
            .appendingPathExtension(fileExtension)
        let manifestURL = artifactDirectoryURL.appendingPathComponent("artifact.json")
        do {
            try FileManager.default.createDirectory(at: artifactsURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: artifactDirectoryURL, withIntermediateDirectories: false)
            try FileManager.default.moveItem(at: sourceURL, to: retainedURL)
            let retainedArtifact = CompressedMediaArtifact(
                assetID: artifact.assetID,
                preset: artifact.preset,
                sourceBytes: artifact.sourceBytes,
                outputBytes: artifact.outputBytes,
                savedBytes: artifact.savedBytes,
                savingsFraction: artifact.savingsFraction,
                outputTypeIdentifier: artifact.outputTypeIdentifier,
                outputCodecIdentifier: artifact.outputCodecIdentifier,
                pixelWidth: artifact.pixelWidth,
                pixelHeight: artifact.pixelHeight,
                videoDuration: artifact.videoDuration,
                videoFrameRate: artifact.videoFrameRate,
                outputURL: retainedURL,
                verifiedSource: artifact.verifiedSource
            )
            let manifest = try JSONEncoder().encode(retainedArtifact)
            try manifest.write(to: manifestURL, options: .atomic)
            guard try fileByteCount(at: retainedURL) == artifact.outputBytes else {
                throw CompressionArtifactRetentionError.byteCountMismatch
            }
            try workspace.cleanup()
            return retainedArtifact
        } catch {
            try? FileManager.default.removeItem(at: artifactDirectoryURL)
            throw error
        }
    }

    func loadRetainedArtifacts() -> [CompressedMediaArtifact] {
        let artifactsURL = rootURL.appendingPathComponent("ReadyForImport", isDirectory: true)
        guard let artifactDirectories = try? FileManager.default.contentsOfDirectory(
            at: artifactsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return artifactDirectories.compactMap(loadRetainedArtifact(at:))
    }

    private func loadRetainedArtifact(at directoryURL: URL) -> CompressedMediaArtifact? {
        let manifestURL = directoryURL.appendingPathComponent("artifact.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let artifact = try? JSONDecoder().decode(CompressedMediaArtifact.self, from: data),
              artifact.outputURL.deletingLastPathComponent().standardizedFileURL == directoryURL.standardizedFileURL,
              (try? fileByteCount(at: artifact.outputURL)) == artifact.outputBytes else {
            let message = "Retained artifact manifest or output is invalid at \(directoryURL.lastPathComponent)"
            AppLogger.shared.warning("CompressionRecovery", message)
            return nil
        }
        return artifact
    }

    private func fileByteCount(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let byteCount = (attributes[.size] as? NSNumber)?.int64Value else {
            throw CompressionArtifactRetentionError.outputSizeUnavailable
        }
        return byteCount
    }

    func create(sourceByteCount: Int64) throws -> CompressionWorkspace {
        guard sourceByteCount > 0 else { throw CompressionWorkspaceError.invalidSourceSize }
        let (requiredBytes, overflow) = sourceByteCount.multipliedReportingOverflow(by: 2)
        guard !overflow else { throw CompressionWorkspaceError.sizeOverflow }
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        } catch {
            throw CompressionWorkspaceError.workspaceCreationFailed
        }
        let availableBytes = try diskSpaceProvider.availableBytes(at: rootURL)
        guard availableBytes >= requiredBytes else {
            throw CompressionWorkspaceError.insufficientDiskSpace(
                required: requiredBytes,
                available: availableBytes
            )
        }
        let workspaceURL = rootURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceDirectoryURL = workspaceURL.appendingPathComponent("source", isDirectory: true)
        let outputDirectoryURL = workspaceURL.appendingPathComponent("output", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: sourceDirectoryURL, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: outputDirectoryURL, withIntermediateDirectories: false)
        } catch {
            try? FileManager.default.removeItem(at: workspaceURL)
            throw CompressionWorkspaceError.workspaceCreationFailed
        }
        return CompressionWorkspace(
            rootURL: workspaceURL,
            sourceDirectoryURL: sourceDirectoryURL,
            outputDirectoryURL: outputDirectoryURL
        )
    }
}

struct CompressionWorkspace {
    let rootURL: URL
    let sourceDirectoryURL: URL
    let outputDirectoryURL: URL

    var sourceURL: URL {
        sourceDirectoryURL.appendingPathComponent("source-resource")
    }

    func sourceURL(for filename: String) -> URL {
        let fileExtension = URL(fileURLWithPath: filename).pathExtension
        guard !fileExtension.isEmpty else { return sourceURL }
        return sourceDirectoryURL
            .appendingPathComponent("source-resource")
            .appendingPathExtension(fileExtension)
    }

    var outputURL: URL {
        outputDirectoryURL.appendingPathComponent("compressed-output")
    }

    func cleanup() throws {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return }
        try FileManager.default.removeItem(at: rootURL)
    }
}

enum CompressionArtifactRetentionError: LocalizedError, Equatable {
    case invalidOutput
    case outputSizeUnavailable
    case byteCountMismatch

    var errorDescription: String? {
        switch self {
        case .invalidOutput: "The compressed artifact is outside its job workspace."
        case .outputSizeUnavailable: "The retained compressed artifact size could not be verified."
        case .byteCountMismatch: "The retained compressed artifact size changed during handoff."
        }
    }
}

enum CompressionWorkspaceError: LocalizedError, Equatable {
    case invalidSourceSize
    case sizeOverflow
    case diskSpaceUnavailable
    case insufficientDiskSpace(required: Int64, available: Int64)
    case workspaceCreationFailed

    var errorDescription: String? {
        switch self {
        case .invalidSourceSize: "The source size must be verified before compression."
        case .sizeOverflow: "The required workspace size cannot be represented safely."
        case .diskSpaceUnavailable: "Available disk space could not be verified."
        case let .insufficientDiskSpace(required, available):
            "Compression needs at least \(required) bytes of free space; \(available) bytes are available."
        case .workspaceCreationFailed: "A private compression workspace could not be created."
        }
    }
}
