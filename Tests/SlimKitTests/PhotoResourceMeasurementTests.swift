import Foundation
import XCTest
@testable import SlimKit

final class PhotoResourceMeasurementTests: XCTestCase {
    func testInjectedSourceMeasuresAndVerifiesWithoutPhotos() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let modificationDate = Date(timeIntervalSince1970: 1_000)
        let verification = SourceVerificationRecorder()
        let source = makeSource(
            bytes: Data([1, 2, 3, 4]),
            modificationDate: modificationDate,
            verifySource: { verification.markVerified() }
        )

        let measurement = try await PhotoResourceExporter.measure(
            assetIdentifier: "test-asset",
            networkAccessAllowed: false,
            source: source,
            temporaryDirectory: directory
        )

        XCTAssertEqual(measurement.size.assetID, "test-asset")
        XCTAssertEqual(measurement.size.byteCount, 4)
        XCTAssertEqual(measurement.size.sourceModificationDate, modificationDate)
        XCTAssertEqual(measurement.size.resourceSelectionBasis, "photo|public.jpeg")
        XCTAssertEqual(measurement.capabilities, .uncertain("Image metadata could not be read."))
        XCTAssertTrue(verification.wasVerified)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        let record = VerifiedSizeRecord(size: measurement.size, capabilities: measurement.capabilities)
        XCTAssertEqual(
            record.capabilityDecision(
                sourceModificationDate: modificationDate,
                resourceSelectionBasis: "photo|public.jpeg"
            ),
            measurement.capabilities
        )
    }

    func testChangedSourceRejectsMeasurementAndCleansWorkspace() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = makeSource(
            bytes: Data([1, 2, 3, 4]),
            modificationDate: Date(timeIntervalSince1970: 1_000),
            verifySource: { throw ResourceExportError.sourceChanged }
        )
        var sourceWasRejected = false

        do {
            _ = try await PhotoResourceExporter.measure(
                assetIdentifier: "test-asset",
                source: source,
                temporaryDirectory: directory
            )
        } catch let error as ResourceExportError {
            sourceWasRejected = error == .sourceChanged
        }

        XCTAssertTrue(sourceWasRejected)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testCancelledTransferSkipsSourceRecheckAndCleansWorkspace() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let verification = SourceVerificationRecorder()
        let source = makeSource(
            bytes: Data([1, 2]),
            modificationDate: Date(timeIntervalSince1970: 1_000),
            transferError: CancellationError(),
            verifySource: { verification.markVerified() }
        )
        var cancellationWasPropagated = false

        do {
            _ = try await PhotoResourceExporter.measure(
                assetIdentifier: "test-asset",
                source: source,
                temporaryDirectory: directory
            )
        } catch is CancellationError {
            cancellationWasPropagated = true
        }

        XCTAssertTrue(cancellationWasPropagated)
        XCTAssertFalse(verification.wasVerified)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SlimKit-Measurement-Test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func makeSource(
        bytes: Data,
        modificationDate: Date,
        transferError: Error? = nil,
        verifySource: @escaping () throws -> Void
    ) -> StubResourceExportSource {
        let selectedResource = SelectedResource(
            sourceModificationDate: modificationDate,
            kind: .photo,
            basis: "photo|public.jpeg",
            filename: "source-resource.jpg",
            transfer: { fileHandle, resourceURL, _, _ in
                try fileHandle.write(contentsOf: bytes)
                if let transferError { throw transferError }
                var counter = ResourceByteCounter()
                try counter.append(bytes.count)
                let attributes = try FileManager.default.attributesOfItem(atPath: resourceURL.path)
                guard let fileByteCount = (attributes[.size] as? NSNumber)?.int64Value else {
                    throw ResourceExportError.exportFailed
                }
                return try counter.verifiedByteCount(fileByteCount: fileByteCount)
            },
            verifySource: verifySource
        )
        return StubResourceExportSource(selectedResource: selectedResource)
    }
}

private struct StubResourceExportSource: ResourceExportSource {
    let selectedResource: SelectedResource
    let canReadPhotos = true

    func selectResource(assetIdentifier: String) throws -> SelectedResource {
        selectedResource
    }
}

private final class SourceVerificationRecorder {
    private(set) var wasVerified = false

    func markVerified() {
        wasVerified = true
    }
}
