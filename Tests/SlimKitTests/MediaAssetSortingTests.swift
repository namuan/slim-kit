import Foundation
import XCTest
@testable import SlimKit

final class MediaAssetSortingTests: XCTestCase {
    func testLargestVerifiedSortUsesCurrentMeasurementsAndKeepsUnknownsLast() {
        let date = Date(timeIntervalSince1970: 1_000)
        let firstUnknown = asset("unknown-1", modificationDate: date)
        let largest = asset("largest", modificationDate: date)
        let stale = asset("stale", modificationDate: date)
        let smaller = asset("smaller", modificationDate: date)
        let secondUnknown = asset("unknown-2", modificationDate: date)
        let records = [
            "largest": record(for: largest, byteCount: 500),
            "stale": record(for: stale, byteCount: 900, sourceDate: date.addingTimeInterval(-1)),
            "smaller": record(for: smaller, byteCount: 100)
        ]

        let sorted = MediaAssetSorter.sorted(
            [firstUnknown, largest, stale, smaller, secondUnknown],
            by: .largestVerified,
            sizeRecords: records
        )

        XCTAssertEqual(sorted.map(\.id), ["largest", "smaller", "unknown-1", "stale", "unknown-2"])
    }

    func testNewestSortKeepsMissingDatesLastAndStableTies() {
        let newest = asset("newest", creationDate: Date(timeIntervalSince1970: 3_000))
        let tiedFirst = asset("tied-1", creationDate: Date(timeIntervalSince1970: 2_000))
        let tiedSecond = asset("tied-2", creationDate: Date(timeIntervalSince1970: 2_000))
        let missingDate = asset("missing", creationDate: nil)

        let sorted = MediaAssetSorter.sorted(
            [tiedFirst, missingDate, newest, tiedSecond],
            by: .newest,
            sizeRecords: [:]
        )

        XCTAssertEqual(sorted.map(\.id), ["newest", "tied-1", "tied-2", "missing"])
    }

    func testLongestVideoSortKeepsPhotosAndUnknownDurationsLast() {
        let shortVideo = asset("short", kind: .video, duration: 10)
        let longest = asset("longest", kind: .video, duration: 60)
        let photo = asset("photo", kind: .photo, duration: nil)
        let unknownVideo = asset("unknown-video", kind: .video, duration: nil)

        let sorted = MediaAssetSorter.sorted(
            [shortVideo, photo, longest, unknownVideo],
            by: .longestVideo,
            sizeRecords: [:]
        )

        XCTAssertEqual(sorted.map(\.id), ["longest", "short", "photo", "unknown-video"])
    }

    private func asset(
        _ id: String,
        kind: MediaAsset.Kind = .photo,
        creationDate: Date? = nil,
        modificationDate: Date? = Date(timeIntervalSince1970: 1_000),
        duration: TimeInterval? = nil
    ) -> MediaAsset {
        MediaAsset(
            id: id,
            kind: kind,
            creationDate: creationDate,
            modificationDate: modificationDate,
            pixelWidth: 10,
            pixelHeight: 10,
            duration: duration,
            isFavorite: false,
            eligibility: .pendingInspection
        )
    }

    private func record(
        for asset: MediaAsset,
        byteCount: Int64,
        sourceDate: Date? = nil
    ) -> VerifiedSizeRecord {
        let date = sourceDate ?? asset.modificationDate ?? .distantPast
        let size = VerifiedResourceSize(
            assetID: asset.id,
            byteCount: byteCount,
            sourceModificationDate: date,
            resourceSelectionBasis: "photo|1|public.jpeg",
            measuredAt: date
        )
        return VerifiedSizeRecord(size: size, capabilities: .supported)
    }
}
