import Foundation
import XCTest
@testable import SlimKit

extension MediaCapabilityInspectorTests {
    func testVideoCompressionRejectsMismatchedVerifiedSizeBeforeEncoding() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SlimKit-Video-Size-Mismatch-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        try await createNoisyVideo(at: sourceURL)
        let sourceBytes = try verifiedFileSize(at: sourceURL)
        let workspace = try compressionWorkspace(sourceBytes: sourceBytes + 1)
        defer { try? workspace.cleanup() }
        let date = Date(timeIntervalSince1970: 1_000)
        let input = LocalCompressionInput(
            sourceURL: sourceURL,
            verifiedSize: VerifiedResourceSize(
                assetID: "video-mismatch",
                byteCount: sourceBytes + 1,
                sourceModificationDate: date,
                resourceSelectionBasis: "video|2|public.mpeg-4",
                measuredAt: date
            ),
            verifySourceIsCurrent: {}
        )

        let attempt = try await VideoCompressionEngine.compress(
            input: input,
            preset: .balanced,
            workspace: workspace
        )

        XCTAssertEqual(attempt, .skipped(.sourceSizeMismatch))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workspace.outputDirectoryURL.path), [])
    }

    func testVideoCompressionProducesValidatedSDROutput() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SlimKit-Video-Compression-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        try await createNoisyVideo(at: sourceURL)
        let sourceBytes = try verifiedFileSize(at: sourceURL)
        let workspace = try compressionWorkspace(sourceBytes: sourceBytes)
        defer { try? workspace.cleanup() }
        let date = Date(timeIntervalSince1970: 1_000)
        let input = LocalCompressionInput(
            sourceURL: sourceURL,
            verifiedSize: VerifiedResourceSize(
                assetID: "video-1",
                byteCount: sourceBytes,
                sourceModificationDate: date,
                resourceSelectionBasis: "video|2|public.mpeg-4",
                measuredAt: date
            ),
            verifySourceIsCurrent: {}
        )

        let attempt = try await VideoCompressionEngine.compress(
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
        XCTAssertEqual(artifact.outputTypeIdentifier, "public.mpeg-4")
        XCTAssertFalse(try XCTUnwrap(artifact.outputCodecIdentifier).isEmpty)
        let outputCapabilities = await MediaCapabilityInspector.inspectVideo(at: artifact.outputURL)
        XCTAssertEqual(outputCapabilities, .supported)
        XCTAssertLessThanOrEqual(artifact.pixelWidth, 320)
        XCTAssertLessThanOrEqual(artifact.pixelHeight, 180)
    }

    private func verifiedFileSize(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap((attributes[.size] as? NSNumber)?.int64Value)
    }

    private func compressionWorkspace(sourceBytes: Int64) throws -> CompressionWorkspace {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SlimKit-Video-Workspace-\(UUID().uuidString)", isDirectory: true)
        return try CompressionWorkspaceManager(
            rootURL: root,
            diskSpaceProvider: FixedVideoDiskSpaceProvider(amount: max(sourceBytes * 2, 1_000_000))
        ).create(sourceByteCount: sourceBytes)
    }
}

private struct FixedVideoDiskSpaceProvider: DiskSpaceProviding {
    let amount: Int64

    func availableBytes(at directory: URL) throws -> Int64 {
        amount
    }
}
