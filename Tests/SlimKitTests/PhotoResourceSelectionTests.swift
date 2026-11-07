import Foundation
import XCTest
@testable import SlimKit

final class PhotoResourceSelectionTests: XCTestCase {
    func testSelectsSingleOriginalPhotoResourceAndBuildsIdentityBasis() throws {
        let selection = try PhotoResourceSelector.select(
            kind: .photo,
            mediaSubtypeRawValue: 0,
            resources: [candidate(type: 1, kind: .photo, uti: "public.jpeg")]
        )

        XCTAssertEqual(selection.kind, .photo)
        XCTAssertEqual(selection.uniformTypeIdentifier, "public.jpeg")
        XCTAssertEqual(selection.resourceSelectionBasis, "photo|1|public.jpeg")
    }

    func testSelectsSingleOriginalVideoResourceAndBuildsIdentityBasis() throws {
        let selection = try PhotoResourceSelector.select(
            kind: .video,
            mediaSubtypeRawValue: 0,
            resources: [candidate(type: 2, kind: .video, uti: "public.mpeg-4")]
        )

        XCTAssertEqual(selection.kind, .video)
        XCTAssertEqual(selection.uniformTypeIdentifier, "public.mpeg-4")
        XCTAssertEqual(selection.resourceSelectionBasis, "video|2|public.mpeg-4")
    }

    func testRejectsAmbiguousResourcesAndSpecialMediaSubtypes() {
        XCTAssertThrowsError(try PhotoResourceSelector.select(
            kind: .photo,
            mediaSubtypeRawValue: 0,
            resources: [
                candidate(type: 1, kind: .photo, uti: "public.jpeg"),
                candidate(type: 3, kind: .pairedVideo, uti: "public.mpeg-4")
            ]
        ))
        XCTAssertThrowsError(try PhotoResourceSelector.select(
            kind: .photo,
            mediaSubtypeRawValue: 1,
            resources: [candidate(type: 1, kind: .photo, uti: "public.jpeg")]
        ))
    }

    func testSourceIdentityRejectsAssetDateOrResourceBasisChanges() {
        let modificationDate = Date(timeIntervalSince1970: 1_000)
        let identity = ResourceExportSourceIdentity(
            assetIdentifier: "asset-1",
            modificationDate: modificationDate,
            resourceSelectionBasis: "photo|1|public.jpeg"
        )

        XCTAssertTrue(identity.matches(
            assetIdentifier: "asset-1",
            modificationDate: modificationDate,
            resourceSelectionBasis: "photo|1|public.jpeg"
        ))
        XCTAssertFalse(identity.matches(
            assetIdentifier: "asset-2",
            modificationDate: modificationDate,
            resourceSelectionBasis: "photo|1|public.jpeg"
        ))
        XCTAssertFalse(identity.matches(
            assetIdentifier: "asset-1",
            modificationDate: modificationDate.addingTimeInterval(1),
            resourceSelectionBasis: "photo|1|public.jpeg"
        ))
        XCTAssertFalse(identity.matches(
            assetIdentifier: "asset-1",
            modificationDate: modificationDate,
            resourceSelectionBasis: "photo|2|public.jpeg"
        ))
    }

    private func candidate(
        type: Int,
        kind: MediaResourceDescriptor.Kind,
        uti: String
    ) -> PhotoResourceCandidate {
        PhotoResourceCandidate(typeRawValue: type, kind: kind, uniformTypeIdentifier: uti)
    }
}
