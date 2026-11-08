import Foundation
import SwiftData
import XCTest
@testable import SlimKit

@MainActor
final class CompressionImportCoordinatorTests: XCTestCase {
    func testImportsAndIndependentlyVerifiesReplacementWithoutTouchingOriginal() async throws {
        let fixture = try makeFixture()
        let importer = FakePhotosAssetImporter(snapshot: fixture.replacementSnapshot)
        let checkpoints = InMemoryCompressionWorkflowStore()
        let result = await CompressionImportCoordinator.importAndVerify(
            request: fixture.request,
            resourceSource: fixture.resources,
            importer: importer,
            checkpointStore: checkpoints
        )

        XCTAssertEqual(result.state, .verified)
        XCTAssertEqual(result.replacementAssetID, "replacement-1")
        XCTAssertEqual(importer.importCount, 1)
        let saved = try checkpoints.snapshot(operationID: fixture.request.operationID)
        XCTAssertEqual(saved?.phase, .awaitingDeletionDecision)
    }

    func testByteCountMismatchFailsVerificationAndPreservesReplacementIdentifier() async throws {
        let fixture = try makeFixture()
        fixture.resources.resourceData["replacement-1"] = fixture.jpegData + Data([0])
        let importer = FakePhotosAssetImporter(snapshot: fixture.replacementSnapshot)
        let checkpoints = InMemoryCompressionWorkflowStore()
        let result = await CompressionImportCoordinator.importAndVerify(
            request: fixture.request,
            resourceSource: fixture.resources,
            importer: importer,
            checkpointStore: checkpoints
        )

        guard case .failed = result.state else {
            return XCTFail("Expected independently measured replacement mismatch to fail")
        }
        XCTAssertEqual(result.replacementAssetID, "replacement-1")
        let saved = try checkpoints.snapshot(operationID: fixture.request.operationID)
        XCTAssertEqual(saved?.replacementAssetID, "replacement-1")
    }

    func testUnavailableReplacementRemainsPendingAndCanResumeWithoutDuplicateImport() async throws {
        let fixture = try makeFixture()
        let importer = FakePhotosAssetImporter(snapshot: nil)
        let checkpoints = InMemoryCompressionWorkflowStore()
        let firstResult = await CompressionImportCoordinator.importAndVerify(
            request: fixture.request,
            resourceSource: fixture.resources,
            importer: importer,
            checkpointStore: checkpoints
        )

        guard case .pending = firstResult.state else {
            return XCTFail("Expected missing replacement to remain pending")
        }
        importer.assetSnapshot = fixture.replacementSnapshot
        let secondResult = await CompressionImportCoordinator.importAndVerify(
            request: fixture.request,
            resourceSource: fixture.resources,
            importer: importer,
            checkpointStore: checkpoints
        )

        XCTAssertEqual(secondResult.state, .verified)
        XCTAssertEqual(importer.importCount, 1)
    }

    func testSelectedCreationDateAndLocationMustBePreserved() async throws {
        let fixture = try makeFixture()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let location = ImportLocation(
            latitude: 37.3317,
            longitude: -122.0301,
            altitude: 4,
            horizontalAccuracy: 3,
            verticalAccuracy: 4,
            timestamp: date
        )
        let replacement = PhotosAssetSnapshot(
            assetID: "replacement-1",
            mediaKind: .photo,
            pixelWidth: 2,
            pixelHeight: 2,
            duration: nil,
            creationDate: date,
            location: location
        )
        let importer = FakePhotosAssetImporter(snapshot: replacement)
        let request = CompressionImportRequest(
            operationID: fixture.request.operationID,
            artifact: fixture.request.artifact,
            mediaKind: .photo,
            metadata: CompressionImportMetadata(creationDate: date, location: location),
            networkAccessAllowed: false
        )

        let result = await CompressionImportCoordinator.importAndVerify(
            request: request,
            resourceSource: fixture.resources,
            importer: importer,
            checkpointStore: InMemoryCompressionWorkflowStore()
        )

        XCTAssertEqual(result.state, .verified)
    }

    func testUncheckpointedPriorImportRequiresReviewInsteadOfRetry() async throws {
        let fixture = try makeFixture()
        let checkpoints = InMemoryCompressionWorkflowStore()
        try checkpoints.save(
            CompressionWorkflowSnapshot(
                operationID: fixture.request.operationID,
                mediaKind: .photo,
                verifiedSource: fixture.request.artifact.verifiedSource,
                artifact: fixture.request.artifact,
                importMetadata: fixture.request.metadata,
                phase: .importing
            )
        )
        let importer = FakePhotosAssetImporter(snapshot: fixture.replacementSnapshot)
        let result = await CompressionImportCoordinator.importAndVerify(
            request: fixture.request,
            resourceSource: fixture.resources,
            importer: importer,
            checkpointStore: checkpoints
        )

        guard case .needsReview = result.state else {
            return XCTFail("Expected uncertain import outcome to require manual review")
        }
        XCTAssertEqual(importer.importCount, 0)
        XCTAssertEqual(try checkpoints.snapshot(operationID: fixture.request.operationID)?.phase, .needsReview)
    }

    func testWorkflowCheckpointRoundTripsThroughSwiftData() throws {
        let fixture = try makeFixture()
        let schema = Schema([CompressionWorkflowRecord.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = SwiftDataCompressionWorkflowStore(modelContext: container.mainContext)
        let snapshot = CompressionWorkflowSnapshot(
            operationID: fixture.request.operationID,
            mediaKind: .photo,
            verifiedSource: fixture.request.artifact.verifiedSource,
            artifact: fixture.request.artifact,
            importMetadata: fixture.request.metadata,
            phase: .verifyingImport,
            replacementAssetID: "replacement-1"
        )

        try store.save(snapshot)

        XCTAssertEqual(try store.snapshot(operationID: snapshot.operationID), snapshot)
        XCTAssertEqual(try store.allSnapshots(), [snapshot])
    }

    private func makeFixture() throws -> CompressionImportFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("compressed.jpg")
        try MediaCapabilityInspectorTests().createSRGBJPEG(at: url)
        let jpegData = try Data(contentsOf: url)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let (verifiedSource, artifact) = makeArtifact(url: url, data: jpegData, date: date)
        let resources = FakeResourceExportSource(
            date: date,
            originalBasis: verifiedSource.resourceSelectionBasis,
            replacementData: jpegData
        )
        let replacement = makeReplacementSnapshot()
        let request = CompressionImportRequest(
            operationID: "operation-1",
            artifact: artifact,
            mediaKind: .photo,
            metadata: CompressionImportMetadata(creationDate: nil, location: nil),
            networkAccessAllowed: false
        )
        return CompressionImportFixture(
            request: request,
            resources: resources,
            importer: FakePhotosAssetImporter(snapshot: replacement),
            replacementSnapshot: replacement,
            jpegData: jpegData,
            directory: directory
        )
    }

    private func makeArtifact(
        url: URL,
        data: Data,
        date: Date
    ) -> (VerifiedResourceSize, CompressedMediaArtifact) {
        let sourceBytes = Int64(data.count + 500)
        let verifiedSource = VerifiedResourceSize(
            assetID: "source-1",
            byteCount: sourceBytes,
            sourceModificationDate: date,
            resourceSelectionBasis: "single-original:source-1",
            measuredAt: date
        )
        let artifact = CompressedMediaArtifact(
            assetID: verifiedSource.assetID,
            preset: .maximumSavings,
            sourceBytes: sourceBytes,
            outputBytes: Int64(data.count),
            savedBytes: 500,
            savingsFraction: Double(500) / Double(sourceBytes),
            outputTypeIdentifier: "public.jpeg",
            outputCodecIdentifier: nil,
            pixelWidth: 2,
            pixelHeight: 2,
            videoDuration: nil,
            videoFrameRate: nil,
            outputURL: url,
            verifiedSource: verifiedSource
        )
        return (verifiedSource, artifact)
    }

    private func makeReplacementSnapshot() -> PhotosAssetSnapshot {
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
}

private struct CompressionImportFixture {
    let request: CompressionImportRequest
    let resources: FakeResourceExportSource
    let importer: FakePhotosAssetImporter
    let replacementSnapshot: PhotosAssetSnapshot
    let jpegData: Data
    let directory: URL
}

private final class FakeResourceExportSource: ResourceExportSource {
    let canReadPhotos = true
    let date: Date
    let originalBasis: String
    var resourceData: [String: Data]

    init(date: Date, originalBasis: String, replacementData: Data) {
        self.date = date
        self.originalBasis = originalBasis
        resourceData = ["replacement-1": replacementData]
    }

    func selectResource(assetIdentifier: String) throws -> SelectedResource {
        let basis = assetIdentifier == "source-1" ? originalBasis : "single-original:\(assetIdentifier)"
        let data = resourceData[assetIdentifier] ?? Data()
        return SelectedResource(
            sourceModificationDate: date,
            kind: .photo,
            basis: basis,
            filename: "\(assetIdentifier).jpg",
            transfer: { fileHandle, _, _, _ in
                try fileHandle.write(contentsOf: data)
                return Int64(data.count)
            },
            verifySource: {}
        )
    }
}

@MainActor
private final class FakePhotosAssetImporter: PhotosAssetImporting {
    let canReadAndWritePhotos = true
    var assetSnapshot: PhotosAssetSnapshot?
    private(set) var importCount = 0

    init(snapshot: PhotosAssetSnapshot?) {
        assetSnapshot = snapshot
    }

    func importAsset(
        from outputURL: URL,
        mediaKind: MediaAsset.Kind,
        metadata: CompressionImportMetadata
    ) async throws -> String {
        importCount += 1
        return "replacement-1"
    }

    func snapshot(assetID: String) async throws -> PhotosAssetSnapshot? {
        assetSnapshot
    }
}

@MainActor
private final class InMemoryCompressionWorkflowStore: CompressionWorkflowCheckpointing {
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
