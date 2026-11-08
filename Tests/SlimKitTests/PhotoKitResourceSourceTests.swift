import Foundation
import XCTest
@testable import SlimKit

final class PhotoKitResourceSourceTests: XCTestCase {
    func testPhotoKitSourceMeasuresThroughCatalogAndRechecksSnapshot() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 1_000)
        let transfers = TransferRecorder()
        let catalog = StubPhotoKitResourceCatalog(snapshots: [
            snapshot(date: date, uti: "public.jpeg", transfers: transfers),
            snapshot(date: date, uti: "public.jpeg", transfers: transfers)
        ])

        let measurement = try await PhotoResourceExporter.measure(
            assetIdentifier: "test-asset",
            source: PhotoKitResourceSource(catalog: catalog),
            temporaryDirectory: directory
        )

        XCTAssertEqual(measurement.size.assetID, "test-asset")
        XCTAssertEqual(measurement.size.byteCount, 4)
        XCTAssertEqual(measurement.size.sourceModificationDate, date)
        XCTAssertEqual(measurement.size.resourceSelectionBasis, "photo|1|public.jpeg")
        XCTAssertEqual(transfers.count, 1)
        XCTAssertEqual(catalog.requestCount, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testPhotoKitSourceRejectsModificationChangeAfterTransfer() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 1_000)
        let transfers = TransferRecorder()
        let catalog = StubPhotoKitResourceCatalog(snapshots: [
            snapshot(date: date, uti: "public.jpeg", transfers: transfers),
            snapshot(date: date.addingTimeInterval(1), uti: "public.jpeg", transfers: transfers)
        ])

        await assertSourceChange(catalog: catalog, directory: directory)

        XCTAssertEqual(transfers.count, 1)
        XCTAssertEqual(catalog.requestCount, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testPhotoKitSourceRejectsResourceBasisChangeAfterTransfer() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 1_000)
        let transfers = TransferRecorder()
        let catalog = StubPhotoKitResourceCatalog(snapshots: [
            snapshot(date: date, uti: "public.jpeg", transfers: transfers),
            snapshot(date: date, uti: "public.heic", transfers: transfers)
        ])

        await assertSourceChange(catalog: catalog, directory: directory)

        XCTAssertEqual(transfers.count, 1)
        XCTAssertEqual(catalog.requestCount, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testPhotoKitSourceCancellationCleansWorkspaceWithoutRechecking() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transfers = TransferRecorder()
        let catalog = StubPhotoKitResourceCatalog(snapshots: [
            snapshot(
                date: Date(timeIntervalSince1970: 1_000),
                uti: "public.jpeg",
                transfers: transfers,
                transferError: CancellationError()
            )
        ])
        var cancellationWasPropagated = false

        do {
            _ = try await PhotoResourceExporter.measure(
                assetIdentifier: "test-asset",
                source: PhotoKitResourceSource(catalog: catalog),
                temporaryDirectory: directory
            )
        } catch is CancellationError {
            cancellationWasPropagated = true
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(cancellationWasPropagated)
        XCTAssertEqual(transfers.count, 1)
        XCTAssertEqual(catalog.requestCount, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testLivePhotoKitCatalogIsDisabledInsideXCTestHost() {
        XCTAssertTrue(PhotosRuntimeEnvironment.isRunningTests)
        let catalog = LivePhotoKitResourceCatalog()

        XCTAssertFalse(catalog.canReadPhotos)
        XCTAssertNil(catalog.snapshot(assetIdentifier: "must-not-be-fetched"))
    }

    func testPhotoKitSourceStopsBeforeSnapshotWhenAccessIsUnavailable() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = StubPhotoKitResourceCatalog(canReadPhotos: false, snapshots: [])
        var accessWasRejected = false

        do {
            _ = try await PhotoResourceExporter.measure(
                assetIdentifier: "test-asset",
                source: PhotoKitResourceSource(catalog: catalog),
                temporaryDirectory: directory
            )
        } catch let error as ResourceExportError {
            accessWasRejected = error == .accessUnavailable
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(accessWasRejected)
        XCTAssertEqual(catalog.requestCount, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    private func assertSourceChange(
        catalog: StubPhotoKitResourceCatalog,
        directory: URL
    ) async {
        var sourceWasRejected = false

        do {
            _ = try await PhotoResourceExporter.measure(
                assetIdentifier: "test-asset",
                source: PhotoKitResourceSource(catalog: catalog),
                temporaryDirectory: directory
            )
        } catch let error as ResourceExportError {
            sourceWasRejected = error == .sourceChanged
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(sourceWasRejected)
    }

    private func snapshot(
        date: Date,
        uti: String,
        transfers: TransferRecorder,
        transferError: Error? = nil
    ) -> PhotoKitAssetSnapshot {
        let data = Data([1, 2, 3, 4])
        let resource = PhotoKitResourceCandidate(
            selection: PhotoResourceCandidate(
                typeRawValue: 1,
                kind: .photo,
                uniformTypeIdentifier: uti
            ),
            transfer: { fileHandle, resourceURL, _ in
                transfers.record()
                try fileHandle.write(contentsOf: data)
                if let transferError { throw transferError }
                var counter = ResourceByteCounter()
                try counter.append(data.count)
                let attributes = try FileManager.default.attributesOfItem(atPath: resourceURL.path)
                guard let fileByteCount = (attributes[.size] as? NSNumber)?.int64Value else {
                    throw ResourceExportError.exportFailed
                }
                return try counter.verifiedByteCount(fileByteCount: fileByteCount)
            }
        )
        return PhotoKitAssetSnapshot(
            assetIdentifier: "test-asset",
            kind: .photo,
            mediaSubtypeRawValue: 0,
            modificationDate: date,
            resources: [resource]
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SlimKit-PhotoKit-Source-Test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}

private final class StubPhotoKitResourceCatalog: PhotoKitResourceCatalog {
    let canReadPhotos: Bool
    private let snapshots: [PhotoKitAssetSnapshot?]
    private(set) var requestCount = 0

    init(canReadPhotos: Bool = true, snapshots: [PhotoKitAssetSnapshot?]) {
        self.canReadPhotos = canReadPhotos
        self.snapshots = snapshots
    }

    func snapshot(assetIdentifier: String) -> PhotoKitAssetSnapshot? {
        defer { requestCount += 1 }
        return snapshots[min(requestCount, snapshots.count - 1)]
    }
}

private final class TransferRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}
