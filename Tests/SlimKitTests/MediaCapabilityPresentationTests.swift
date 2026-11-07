import Foundation
import XCTest
@testable import SlimKit

final class MediaCapabilityPresentationTests: XCTestCase {
    func testStaleCapabilityDecisionIsNotPresentedAfterSourceModification() {
        let originalDate = Date(timeIntervalSince1970: 1_000)
        let size = VerifiedResourceSize(
            assetID: "asset-1",
            byteCount: 2_048,
            sourceModificationDate: originalDate,
            resourceSelectionBasis: "photo|1|public.jpeg",
            measuredAt: originalDate
        )
        let record = VerifiedSizeRecord(size: size, capabilities: .unsupported("depth"))
        let originalAsset = asset(modificationDate: originalDate)
        let changedAsset = asset(modificationDate: originalDate.addingTimeInterval(1))

        XCTAssertEqual(
            MediaCapabilityCachePresentation.asset(for: originalAsset, record: record).eligibility,
            .unsupported("depth")
        )
        XCTAssertEqual(
            MediaCapabilityCachePresentation.asset(for: changedAsset, record: record).eligibility,
            .pendingInspection
        )
        XCTAssertNil(MediaCapabilityCachePresentation.decision(for: changedAsset, record: record))
    }

    private func asset(modificationDate: Date) -> MediaAsset {
        MediaAsset(
            id: "asset-1",
            kind: .photo,
            creationDate: nil,
            modificationDate: modificationDate,
            pixelWidth: 2,
            pixelHeight: 2,
            duration: nil,
            isFavorite: false,
            eligibility: .pendingInspection
        )
    }
}
