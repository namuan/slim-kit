import AVFoundation
import Foundation
import XCTest
@testable import SlimKit

final class CompressionWorkspaceTests: XCTestCase {
    func testPresetPoliciesAreExplicitAndOrderedByAggressiveness() {
        let highQuality = CompressionPreset.highQuality.policy
        let balanced = CompressionPreset.balanced.policy
        let maximumSavings = CompressionPreset.maximumSavings.policy

        XCTAssertGreaterThan(highQuality.imageQuality, balanced.imageQuality)
        XCTAssertGreaterThan(balanced.imageQuality, maximumSavings.imageQuality)
        XCTAssertNil(highQuality.maximumImageDimension)
        XCTAssertNil(balanced.maximumImageDimension)
        XCTAssertNil(highQuality.maximumVideoDimension)
        XCTAssertEqual(balanced.maximumVideoDimension, 1_920)
        XCTAssertEqual(maximumSavings.maximumImageDimension, 2_048)
        XCTAssertEqual(maximumSavings.maximumVideoDimension, 1_280)
        XCTAssertEqual(highQuality.minimumSavingsFraction, 0.05)
        XCTAssertEqual(balanced.minimumSavingsFraction, 0.05)
        XCTAssertEqual(maximumSavings.minimumSavingsFraction, 0.05)
        XCTAssertEqual(highQuality.videoExportPreset, AVAssetExportPresetHighestQuality)
        XCTAssertEqual(balanced.videoExportPreset, AVAssetExportPresetMediumQuality)
        XCTAssertEqual(maximumSavings.videoExportPreset, AVAssetExportPresetLowQuality)
    }

    func testWorkspaceUsesIsolatedSourceAndOutputDirectoriesAndCleansUp() throws {
        let parent = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let manager = CompressionWorkspaceManager(
            rootURL: parent.appendingPathComponent("Jobs", isDirectory: true),
            diskSpaceProvider: FixedDiskSpaceProvider(amount: 1_000)
        )

        let workspace = try manager.create(sourceByteCount: 400)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.sourceDirectoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.outputDirectoryURL.path))
        XCTAssertNotEqual(workspace.sourceURL, workspace.outputURL)
        XCTAssertTrue(workspace.rootURL.path.hasPrefix(manager.rootURL.path))

        try workspace.cleanup()

        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.rootURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.rootURL.path))
    }

    func testWorkspaceRejectsInsufficientOrUnverifiableStorage() throws {
        let parent = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let manager = CompressionWorkspaceManager(
            rootURL: parent.appendingPathComponent("Jobs", isDirectory: true),
            diskSpaceProvider: FixedDiskSpaceProvider(amount: 799)
        )

        XCTAssertThrowsError(try manager.create(sourceByteCount: 400)) { error in
            XCTAssertEqual(
                error as? CompressionWorkspaceError,
                .insufficientDiskSpace(required: 800, available: 799)
            )
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: manager.rootURL.path), [])
        XCTAssertThrowsError(try manager.create(sourceByteCount: 0)) { error in
            XCTAssertEqual(error as? CompressionWorkspaceError, .invalidSourceSize)
        }
        XCTAssertThrowsError(try manager.create(sourceByteCount: Int64.max)) { error in
            XCTAssertEqual(error as? CompressionWorkspaceError, .sizeOverflow)
        }
    }

    func testWorkspaceFailsClosedWhenDiskSpaceCannotBeRead() throws {
        let parent = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let manager = CompressionWorkspaceManager(
            rootURL: parent.appendingPathComponent("Jobs", isDirectory: true),
            diskSpaceProvider: UnavailableDiskSpaceProvider()
        )

        XCTAssertThrowsError(try manager.create(sourceByteCount: 100)) { error in
            XCTAssertEqual(error as? CompressionWorkspaceError, .diskSpaceUnavailable)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: manager.rootURL.path), [])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SlimKit-Workspace-Test-\(UUID().uuidString)", isDirectory: true)
    }
}

private struct FixedDiskSpaceProvider: DiskSpaceProviding {
    let amount: Int64

    func availableBytes(at directory: URL) throws -> Int64 {
        amount
    }
}

private struct UnavailableDiskSpaceProvider: DiskSpaceProviding {
    func availableBytes(at directory: URL) throws -> Int64 {
        throw CompressionWorkspaceError.diskSpaceUnavailable
    }
}
