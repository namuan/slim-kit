import Foundation
import SwiftData
import XCTest
@testable import SlimKit

@MainActor
final class CompressionDeletionCoordinatorTests: XCTestCase {
    func testDeletionRequiresSeparateConfirmationAndRechecksBothAssets() async throws {
        let fixture = try await makeFixture()
        let review = await review(fixture)
        XCTAssertTrue(review.isReadyForConfirmation)
        XCTAssertEqual(fixture.deletionService.deleteCount, 0)

        let result = await delete(fixture, confirmed: false)

        guard case .confirmationRequired = result else {
            return XCTFail("Expected explicit confirmation before deletion")
        }
        XCTAssertEqual(fixture.deletionService.deleteCount, 0)
        XCTAssertTrue(fixture.importer.sourceExists)
    }

    func testExplicitConfirmationDeletesOnlyOriginalAfterFreshVerification() async throws {
        let fixture = try await makeFixture()

        let result = await delete(fixture, confirmed: true)

        XCTAssertEqual(result, .deleted)
        XCTAssertEqual(fixture.deletionService.deleteCount, 1)
        XCTAssertFalse(fixture.importer.sourceExists)
        let snapshot = try XCTUnwrap(fixture.checkpoints.snapshot(operationID: fixture.snapshot.operationID))
        XCTAssertEqual(snapshot.phase, .completed)
        XCTAssertTrue(snapshot.deletionApprovalRecorded)
        XCTAssertTrue(snapshot.deletionTransactionSucceeded)
    }

    func testChangedSourceBlocksDeletion() async throws {
        let fixture = try await makeFixture()
        fixture.resources.sourceIsCurrent = false

        let result = await delete(fixture, confirmed: true)

        guard case .blocked = result else {
            return XCTFail("Expected changed source to block deletion")
        }
        XCTAssertEqual(fixture.deletionService.deleteCount, 0)
        XCTAssertTrue(fixture.importer.sourceExists)
    }

    func testUncertainDeletionRecoveryNeverRetriesDelete() async throws {
        let fixture = try await makeFixture()
        let deleting = fixture.snapshot.updating(
            phase: .deletingOriginal,
            deletionRequested: true,
            deletionApprovalRecorded: true
        )
        try fixture.checkpoints.save(deleting)

        let result = await CompressionDeletionCoordinator.recoverInterruptedDeletion(
            operationID: deleting.operationID,
            context: deletionContext(fixture)
        )

        guard case .needsReview = result else {
            return XCTFail("Expected existing original to require manual review")
        }
        XCTAssertEqual(fixture.deletionService.deleteCount, 0)
        XCTAssertTrue(fixture.importer.sourceExists)
        XCTAssertEqual(try fixture.checkpoints.snapshot(operationID: deleting.operationID)?.phase, .needsReview)
    }

    func testRecoveryReconcilesAlreadyCompletedDeletionWithoutRepeatingIt() async throws {
        let fixture = try await makeFixture()
        let deleting = fixture.snapshot.updating(
            phase: .deletingOriginal,
            deletionRequested: true,
            deletionApprovalRecorded: true
        )
        try fixture.checkpoints.save(deleting)
        fixture.importer.sourceExists = false

        let result = await CompressionDeletionCoordinator.recoverInterruptedDeletion(
            operationID: deleting.operationID,
            context: deletionContext(fixture)
        )

        XCTAssertEqual(result, .deleted)
        XCTAssertEqual(fixture.deletionService.deleteCount, 0)
        XCTAssertEqual(try fixture.checkpoints.snapshot(operationID: deleting.operationID)?.phase, .completed)
    }

    private func makeFixture() async throws -> DeletionFixture {
        let files = try await makeFixtureFiles()
        let sourceSize = verifiedSourceSize(data: files.sourceData, date: files.date)
        let artifact = compressedArtifact(
            sourceSize: sourceSize,
            sourceData: files.sourceData,
            outputData: files.outputData,
            outputURL: files.outputURL
        )
        let replacement = replacementSnapshot()
        let resources = DeletionFakeResourceSource(
            date: files.date,
            originalBasis: sourceSize.resourceSelectionBasis,
            sourceData: files.sourceData,
            replacementID: replacement.assetID,
            replacementData: files.outputData
        )
        let importer = DeletionFakePhotosImporter(replacement: replacement)
        let deletionService = DeletionFakePhotosService(importer: importer)
        let checkpoints = DeletionFakeWorkflowStore()
        let snapshot = CompressionWorkflowSnapshot(
            operationID: "deletion-operation",
            mediaKind: .photo,
            verifiedSource: sourceSize,
            artifact: artifact,
            importMetadata: CompressionImportMetadata(creationDate: nil, location: nil),
            phase: .awaitingDeletionDecision,
            replacementAssetID: replacement.assetID
        )
        try checkpoints.save(snapshot)
        return DeletionFixture(
            snapshot: snapshot,
            resources: resources,
            importer: importer,
            deletionService: deletionService,
            checkpoints: checkpoints
        )
    }

    private func makeFixtureFiles() async throws -> DeletionFixtureFiles {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = directory.appendingPathComponent("compressed.jpg")
        let sourceURL = directory.appendingPathComponent("source.jpg")
        try MediaCapabilityInspectorTests().createSRGBJPEG(at: outputURL)
        try MediaCapabilityInspectorTests().createNoisySRGBJPEG(at: sourceURL)
        return DeletionFixtureFiles(
            outputURL: outputURL,
            outputData: try Data(contentsOf: outputURL),
            sourceData: try Data(contentsOf: sourceURL),
            date: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func verifiedSourceSize(data: Data, date: Date) -> VerifiedResourceSize {
        VerifiedResourceSize(
            assetID: "source-1",
            byteCount: Int64(data.count),
            sourceModificationDate: date,
            resourceSelectionBasis: "single-original:source-1",
            measuredAt: date
        )
    }

    private func compressedArtifact(
        sourceSize: VerifiedResourceSize,
        sourceData: Data,
        outputData: Data,
        outputURL: URL
    ) -> CompressedMediaArtifact {
        let savedBytes = Int64(sourceData.count - outputData.count)
        return CompressedMediaArtifact(
            assetID: sourceSize.assetID,
            preset: .maximumSavings,
            sourceBytes: sourceSize.byteCount,
            outputBytes: Int64(outputData.count),
            savedBytes: savedBytes,
            savingsFraction: Double(savedBytes) / Double(sourceData.count),
            outputTypeIdentifier: "public.jpeg",
            outputCodecIdentifier: nil,
            pixelWidth: 2,
            pixelHeight: 2,
            videoDuration: nil,
            videoFrameRate: nil,
            outputURL: outputURL,
            verifiedSource: sourceSize
        )
    }

    private func replacementSnapshot() -> PhotosAssetSnapshot {
        PhotosAssetSnapshot(
            assetID: "replacement-1",
            mediaKind: .photo,
            pixelWidth: 2,
            pixelHeight: 2,
            duration: nil,
            creationDate: nil,
            location: nil
        )
    }

    private func review(_ fixture: DeletionFixture) async -> OriginalDeletionReview {
        await CompressionDeletionCoordinator.reviewDeletion(
            operationID: fixture.snapshot.operationID,
            context: deletionContext(fixture)
        )
    }

    private func deletionContext(_ fixture: DeletionFixture) -> CompressionDeletionContext {
        CompressionDeletionContext(
            networkAccessAllowed: false,
            resourceSource: fixture.resources,
            importer: fixture.importer,
            deletionService: fixture.deletionService,
            checkpointStore: fixture.checkpoints
        )
    }

    private func delete(_ fixture: DeletionFixture, confirmed: Bool) async -> OriginalDeletionResult {
        await CompressionDeletionCoordinator.deleteOriginal(
            operationID: fixture.snapshot.operationID,
            userConfirmed: confirmed,
            context: deletionContext(fixture)
        )
    }
}

private struct DeletionFixtureFiles {
    let outputURL: URL
    let outputData: Data
    let sourceData: Data
    let date: Date
}

@MainActor
private final class DeletionFixture {
    let snapshot: CompressionWorkflowSnapshot
    let resources: DeletionFakeResourceSource
    let importer: DeletionFakePhotosImporter
    let deletionService: DeletionFakePhotosService
    let checkpoints: DeletionFakeWorkflowStore

    init(
        snapshot: CompressionWorkflowSnapshot,
        resources: DeletionFakeResourceSource,
        importer: DeletionFakePhotosImporter,
        deletionService: DeletionFakePhotosService,
        checkpoints: DeletionFakeWorkflowStore
    ) {
        self.snapshot = snapshot
        self.resources = resources
        self.importer = importer
        self.deletionService = deletionService
        self.checkpoints = checkpoints
    }
}

private final class DeletionFakeResourceSource: ResourceExportSource {
    let canReadPhotos = true
    let date: Date
    let originalBasis: String
    let sourceData: Data
    let replacementID: String
    let replacementData: Data
    var sourceIsCurrent = true

    init(date: Date, originalBasis: String, sourceData: Data, replacementID: String, replacementData: Data) {
        self.date = date
        self.originalBasis = originalBasis
        self.sourceData = sourceData
        self.replacementID = replacementID
        self.replacementData = replacementData
    }

    func selectResource(assetIdentifier: String) throws -> SelectedResource {
        let isSource = assetIdentifier == "source-1"
        let data = isSource ? sourceData : replacementData
        let basis = isSource ? originalBasis : "single-original:\(assetIdentifier)"
        return SelectedResource(
            sourceModificationDate: date,
            kind: .photo,
            basis: basis,
            filename: "\(assetIdentifier).jpg",
            transfer: { fileHandle, _, _, _ in
                try fileHandle.write(contentsOf: data)
                return Int64(data.count)
            },
            verifySource: {
                if isSource && !self.sourceIsCurrent { throw ResourceExportError.sourceChanged }
            }
        )
    }
}

@MainActor
private final class DeletionFakePhotosImporter: PhotosAssetImporting {
    let canReadAndWritePhotos = true
    var sourceExists = true
    let replacement: PhotosAssetSnapshot

    init(replacement: PhotosAssetSnapshot) {
        self.replacement = replacement
    }

    func importAsset(
        from outputURL: URL,
        mediaKind: MediaAsset.Kind,
        metadata: CompressionImportMetadata
    ) async throws -> String {
        replacement.assetID
    }

    func snapshot(assetID: String) async throws -> PhotosAssetSnapshot? {
        if assetID == "source-1" { return sourceExists ? replacementSourceSnapshot : nil }
        return assetID == replacement.assetID ? replacement : nil
    }

    private var replacementSourceSnapshot: PhotosAssetSnapshot {
        PhotosAssetSnapshot(
            assetID: "source-1",
            mediaKind: .photo,
            pixelWidth: replacement.pixelWidth,
            pixelHeight: replacement.pixelHeight,
            duration: nil,
            creationDate: nil,
            location: nil
        )
    }
}

@MainActor
private final class DeletionFakePhotosService: PhotosAssetDeleting {
    let canDeletePhotos = true
    let importer: DeletionFakePhotosImporter
    private(set) var deleteCount = 0

    init(importer: DeletionFakePhotosImporter) {
        self.importer = importer
    }

    func deleteAsset(assetID: String) async throws {
        deleteCount += 1
        importer.sourceExists = false
    }
}

@MainActor
private final class DeletionFakeWorkflowStore: CompressionWorkflowCheckpointing {
    private var snapshots: [String: CompressionWorkflowSnapshot] = [:]

    func save(_ snapshot: CompressionWorkflowSnapshot) throws {
        snapshots[snapshot.operationID] = snapshot
    }

    func snapshot(operationID: String) throws -> CompressionWorkflowSnapshot? {
        snapshots[operationID]
    }

    func allSnapshots() throws -> [CompressionWorkflowSnapshot] {
        Array(snapshots.values)
    }
}
