import Foundation
import ImageIO
import XCTest
@testable import SlimKit

extension MediaCapabilityInspectorTests {
    func testImageCompressionProducesSmallerValidatedOutputAndPreservesOrientation() throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SlimKit-Compression-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        try createNoisySRGBJPEG(at: sourceURL)
        let sourceBytes = try verifiedFileSize(at: sourceURL)
        let workspace = try compressionWorkspace(sourceBytes: sourceBytes)
        defer { try? workspace.cleanup() }
        let modificationDate = Date(timeIntervalSince1970: 1_000)
        let input = LocalCompressionInput(
            sourceURL: sourceURL,
            verifiedSize: VerifiedResourceSize(
                assetID: "image-1",
                byteCount: sourceBytes,
                sourceModificationDate: modificationDate,
                resourceSelectionBasis: "photo|1|public.jpeg",
                measuredAt: modificationDate
            ),
            verifySourceIsCurrent: {}
        )

        let attempt = try ImageCompressionEngine.compress(
            input: input,
            preset: .balanced,
            workspace: workspace
        )

        guard case let .compressed(artifact) = attempt else {
            XCTFail("Expected compressed artifact, got \(attempt)")
            return
        }
        XCTAssertLessThan(artifact.outputBytes, artifact.sourceBytes)
        XCTAssertGreaterThanOrEqual(artifact.savingsFraction, 0.05)
        XCTAssertEqual(artifact.outputTypeIdentifier, "public.jpeg")
        XCTAssertEqual(MediaCapabilityInspector.inspectImage(at: artifact.outputURL), .supported)
        let outputSource = try XCTUnwrap(CGImageSourceCreateWithURL(artifact.outputURL as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(outputSource, 0, nil) as? [String: Any])
        XCTAssertEqual((properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue, 6)
    }

    func testImageCompressionSkipsUnsupportedAuxiliarySource() throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SlimKit-Compression-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        try createDepthJPEG(at: sourceURL)
        let sourceBytes = try verifiedFileSize(at: sourceURL)
        let workspace = try compressionWorkspace(sourceBytes: sourceBytes)
        defer { try? workspace.cleanup() }
        let input = compressionInput(sourceURL: sourceURL, byteCount: sourceBytes)

        let attempt = try ImageCompressionEngine.compress(input: input, preset: .balanced, workspace: workspace)

        XCTAssertEqual(
            attempt,
            .skipped(.unsupportedSource("unsupported: The image contains auxiliary data: depth."))
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workspace.outputDirectoryURL.path), [])
    }

    func testImageCompressionRejectsMismatchedVerifiedSourceSize() throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SlimKit-Compression-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        try createSRGBJPEG(at: sourceURL)
        let actualBytes = try verifiedFileSize(at: sourceURL)
        let workspace = try compressionWorkspace(sourceBytes: actualBytes)
        defer { try? workspace.cleanup() }
        let input = compressionInput(sourceURL: sourceURL, byteCount: actualBytes + 1)

        let attempt = try ImageCompressionEngine.compress(input: input, preset: .balanced, workspace: workspace)

        XCTAssertEqual(attempt, .skipped(.sourceSizeMismatch))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workspace.outputDirectoryURL.path), [])
    }

    func testImageCompressionRechecksSourceAfterEncodingAndRemovesOutputOnChange() throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SlimKit-Compression-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        try createNoisySRGBJPEG(at: sourceURL)
        let sourceBytes = try verifiedFileSize(at: sourceURL)
        let workspace = try compressionWorkspace(sourceBytes: sourceBytes)
        defer { try? workspace.cleanup() }
        var verificationCount = 0
        let input = compressionInput(sourceURL: sourceURL, byteCount: sourceBytes) {
            verificationCount += 1
            if verificationCount > 1 { throw CompressionEngineError.sourceChanged }
        }
        var sourceChangeWasRejected = false

        do {
            _ = try ImageCompressionEngine.compress(input: input, preset: .balanced, workspace: workspace)
        } catch let error as CompressionEngineError {
            sourceChangeWasRejected = error == .sourceChanged
        }

        XCTAssertTrue(sourceChangeWasRejected)
        XCTAssertEqual(verificationCount, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workspace.outputDirectoryURL.path), [])
    }

    private func compressionInput(
        sourceURL: URL,
        byteCount: Int64,
        verifySourceIsCurrent: @escaping () throws -> Void = {}
    ) -> LocalCompressionInput {
        let date = Date(timeIntervalSince1970: 1_000)
        return LocalCompressionInput(
            sourceURL: sourceURL,
            verifiedSize: VerifiedResourceSize(
                assetID: "image-1",
                byteCount: byteCount,
                sourceModificationDate: date,
                resourceSelectionBasis: "photo|1|public.jpeg",
                measuredAt: date
            ),
            verifySourceIsCurrent: verifySourceIsCurrent
        )
    }

    private func verifiedFileSize(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap((attributes[.size] as? NSNumber)?.int64Value)
    }

    private func compressionWorkspace(sourceBytes: Int64) throws -> CompressionWorkspace {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SlimKit-Compression-Workspace-\(UUID().uuidString)", isDirectory: true)
        return try CompressionWorkspaceManager(
            rootURL: root,
            diskSpaceProvider: FixedCompressionDiskSpaceProvider(amount: max(sourceBytes * 2, 1_000_000))
        ).create(sourceByteCount: sourceBytes)
    }
}

private struct FixedCompressionDiskSpaceProvider: DiskSpaceProviding {
    let amount: Int64

    func availableBytes(at directory: URL) throws -> Int64 {
        amount
    }
}
