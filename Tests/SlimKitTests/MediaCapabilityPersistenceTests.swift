import Foundation
import SwiftData
import XCTest
@testable import SlimKit

extension MediaCapabilityInspectorTests {
    @MainActor
    func testCapabilityCacheSurvivesDiskStoreReopen() throws {
        let fixture = try makeCapabilityCacheFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let container = try persistentContainer(at: fixture.storeURL)
        let record = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<VerifiedSizeRecord>()).first)

        XCTAssertEqual(
            record.capabilityDecision(
                sourceModificationDate: fixture.modificationDate,
                resourceSelectionBasis: fixture.resourceBasis
            ),
            .supported
        )
        XCTAssertEqual(
            MediaCapabilityCacheRestorer.decision(
                eligibility: .pendingInspection,
                assetID: "video-asset",
                sourceModificationDate: fixture.modificationDate,
                record: record
            ),
            .supported
        )
    }

    @MainActor
    func testReopenedCapabilityCacheRejectsStaleIdentity() throws {
        let fixture = try makeCapabilityCacheFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let container = try persistentContainer(at: fixture.storeURL)
        let record = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<VerifiedSizeRecord>()).first)

        XCTAssertNil(record.capabilityDecision(
            sourceModificationDate: fixture.modificationDate.addingTimeInterval(1),
            resourceSelectionBasis: fixture.resourceBasis
        ))
        XCTAssertNil(record.capabilityDecision(
            sourceModificationDate: fixture.modificationDate,
            resourceSelectionBasis: "video|public.heic"
        ))
        record.capabilityInspectorVersion = MediaCapabilityInspector.version - 1
        XCTAssertNil(record.capabilityDecision(
            sourceModificationDate: fixture.modificationDate,
            resourceSelectionBasis: fixture.resourceBasis
        ))
    }
}

private struct CapabilityCacheFixture {
    let directory: URL
    let storeURL: URL
    let modificationDate: Date
    let resourceBasis: String
}

@MainActor
private func makeCapabilityCacheFixture() throws -> CapabilityCacheFixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SlimKit-Cache-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let storeURL = directory.appendingPathComponent("VerifiedSizes.store")
    let modificationDate = Date(timeIntervalSince1970: 1_000)
    let resourceBasis = "video|public.mpeg-4"
    let size = VerifiedResourceSize(
        assetID: "video-asset",
        byteCount: 2_048,
        sourceModificationDate: modificationDate,
        resourceSelectionBasis: resourceBasis,
        measuredAt: modificationDate
    )
    let container = try persistentContainer(at: storeURL)
    container.mainContext.insert(VerifiedSizeRecord(size: size, capabilities: .supported))
    try container.mainContext.save()
    return CapabilityCacheFixture(
        directory: directory,
        storeURL: storeURL,
        modificationDate: modificationDate,
        resourceBasis: resourceBasis
    )
}

@MainActor
private func persistentContainer(at url: URL) throws -> ModelContainer {
    try ModelContainer(
        for: VerifiedSizeRecord.self,
        configurations: ModelConfiguration(url: url)
    )
}
