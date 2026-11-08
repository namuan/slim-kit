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

    var outputURL: URL {
        outputDirectoryURL.appendingPathComponent("compressed-output")
    }

    func cleanup() throws {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return }
        try FileManager.default.removeItem(at: rootURL)
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
