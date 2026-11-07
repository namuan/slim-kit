import CoreMedia
import SwiftData
import XCTest
@testable import SlimKit

final class MediaCapabilityInspectorTests: XCTestCase {
    func testAcceptsKnownSingleFrameSRGBImage() {
        XCTAssertEqual(
            MediaCapabilityInspector.assessImage(
                ImageSourceCapabilities(
                    typeIdentifier: "public.jpeg",
                    frameCount: 1,
                    hasAlpha: false,
                    bitDepth: 8,
                    colorProfile: "sRGB IEC61966-2.1",
                    exifColorSpace: nil,
                    auxiliaryDataTypes: []
                )
            ),
            .supported
        )
    }

    func testRejectsWideGamutHighBitDepthAndAuxiliaryImages() {
        XCTAssertEqual(
            MediaCapabilityInspector.assessImage(
                imageCapabilities(colorProfile: "Display P3")
            ),
            .unsupported("Wide-gamut images are not supported by the current output policy.")
        )
        XCTAssertEqual(
            MediaCapabilityInspector.assessImage(
                imageCapabilities(bitDepth: 16)
            ),
            .unsupported("High-bit-depth images are not supported.")
        )
        XCTAssertEqual(
            MediaCapabilityInspector.assessImage(
                imageCapabilities(auxiliaryDataTypes: ["depth"])
            ),
            .unsupported("The image contains auxiliary data: depth.")
        )
    }

    func testRejectsAnimatedAndTransparentImages() {
        XCTAssertEqual(
            MediaCapabilityInspector.assessImage(
                imageCapabilities(frameCount: 3)
            ),
            .unsupported("Multi-frame or animated images are not supported.")
        )
        XCTAssertEqual(
            MediaCapabilityInspector.assessImage(
                imageCapabilities(hasAlpha: true)
            ),
            .unsupported("Transparent images are not supported by the current output policy.")
        )
    }

    func testImageInspectorReadsAnEncodedSRGBSource() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try createSRGBJPEG(at: url)

        XCTAssertEqual(MediaCapabilityInspector.inspectImage(at: url), .supported)
    }

    func testUnreadableImageSourceIsUncertain() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(
            MediaCapabilityInspector.inspectImage(at: url),
            .uncertain("Image metadata could not be read.")
        )
    }

    func testUnknownImageColorProfileIsUncertain() {
        XCTAssertEqual(
            MediaCapabilityInspector.assessImage(
                imageCapabilities(colorProfile: nil, exifColorSpace: nil)
            ),
            .uncertain("The image color profile is missing or unrecognized.")
        )
    }

    func testAcceptsKnownSDRVideoWithOneVideoTrack() {
        XCTAssertEqual(
            MediaCapabilityInspector.assessVideo(
                videoCapabilities()
            ),
            .supported
        )
    }

    func testRejectsHDRWideGamutAndAdditionalVideoTracks() {
        XCTAssertEqual(
            MediaCapabilityInspector.assessVideo(
                videoCapabilities(transferFunction: "SMPTE ST 2084 (PQ)")
            ),
            .unsupported("HDR video is not supported by the current output policy.")
        )
        XCTAssertEqual(
            MediaCapabilityInspector.assessVideo(
                videoCapabilities(colorPrimaries: "P3_D65")
            ),
            .unsupported("Wide-gamut video is not supported by the current output policy.")
        )
        XCTAssertEqual(
            MediaCapabilityInspector.assessVideo(
                videoCapabilities(videoTrackCount: 2)
            ),
            .unsupported("The video must contain exactly one video track.")
        )
        XCTAssertEqual(
            MediaCapabilityInspector.assessVideo(
                videoCapabilities(otherTrackCount: 1)
            ),
            .unsupported("Multiple audio tracks or additional timed tracks are not supported.")
        )
        XCTAssertEqual(
            MediaCapabilityInspector.assessVideo(
                videoCapabilities(videoCodecType: 0)
            ),
            .unsupported("The video codec is not supported for compression.")
        )
    }

    func testVideoInspectorReadsGeneratedSDRVideo() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await createSDRVideo(at: url)

        let decision = await MediaCapabilityInspector.inspectVideo(at: url)
        XCTAssertEqual(decision, .supported)
    }

    func testUnknownVideoColorMetadataIsUncertain() {
        XCTAssertEqual(
            MediaCapabilityInspector.assessVideo(
                videoCapabilities(colorPrimaries: nil)
            ),
            .uncertain("Video color metadata is missing.")
        )
    }

    func testCapabilityCacheInvalidatesWhenSourceBasisOrInspectorChanges() {
        let modificationDate = Date(timeIntervalSince1970: 1_000)
        let identity = MediaCapabilityCacheIdentity(
            sourceModificationDate: modificationDate,
            resourceSelectionBasis: "photo|public.jpeg",
            inspectorVersion: MediaCapabilityInspector.version
        )
        XCTAssertTrue(identity.matches(
            sourceModificationDate: modificationDate,
            resourceSelectionBasis: "photo|public.jpeg",
            inspectorVersion: MediaCapabilityInspector.version
        ))
        XCTAssertFalse(identity.matches(
            sourceModificationDate: modificationDate.addingTimeInterval(1),
            resourceSelectionBasis: "photo|public.jpeg",
            inspectorVersion: MediaCapabilityInspector.version
        ))
        XCTAssertFalse(identity.matches(
            sourceModificationDate: modificationDate,
            resourceSelectionBasis: "video|public.mpeg-4",
            inspectorVersion: MediaCapabilityInspector.version
        ))
        XCTAssertFalse(identity.matches(
            sourceModificationDate: modificationDate,
            resourceSelectionBasis: "photo|public.jpeg",
            inspectorVersion: MediaCapabilityInspector.version + 1
        ))
    }

    @MainActor
    func testSwiftDataCapabilityCachePersistsAndInvalidates() throws {
        let container = try ModelContainer(
            for: VerifiedSizeRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let modificationDate = Date(timeIntervalSince1970: 1_000)
        let resourceBasis = "photo|public.jpeg"
        let size = VerifiedResourceSize(
            assetID: "asset-1",
            byteCount: 1_024,
            sourceModificationDate: modificationDate,
            resourceSelectionBasis: resourceBasis,
            measuredAt: modificationDate
        )
        context.insert(VerifiedSizeRecord(size: size, capabilities: .unsupported("wide gamut")))
        try context.save()
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<VerifiedSizeRecord>()).first)

        XCTAssertEqual(
            record.capabilityDecision(
                sourceModificationDate: modificationDate,
                resourceSelectionBasis: resourceBasis
            ),
            .unsupported("wide gamut")
        )
        XCTAssertNil(record.capabilityDecision(
            sourceModificationDate: modificationDate.addingTimeInterval(1),
            resourceSelectionBasis: resourceBasis
        ))
        XCTAssertNil(record.capabilityDecision(
            sourceModificationDate: modificationDate,
            resourceSelectionBasis: "photo|public.heic"
        ))
        record.capabilityInspectorVersion = MediaCapabilityInspector.version - 1
        XCTAssertNil(record.capabilityDecision(
            sourceModificationDate: modificationDate,
            resourceSelectionBasis: resourceBasis
        ))
    }

    func testPersistedCapabilityDecisionRequiresCurrentInspectorVersion() {
        XCTAssertEqual(
            MediaCapabilityDecision.restore(
                status: "supported",
                reason: nil,
                inspectorVersion: MediaCapabilityInspector.version
            ),
            .supported
        )
        XCTAssertEqual(
            MediaCapabilityDecision.restore(
                status: "unsupported",
                reason: "wide gamut",
                inspectorVersion: MediaCapabilityInspector.version
            ),
            .unsupported("wide gamut")
        )
        XCTAssertNil(
            MediaCapabilityDecision.restore(
                status: "supported",
                reason: nil,
                inspectorVersion: MediaCapabilityInspector.version - 1
            )
        )
        XCTAssertNil(
            MediaCapabilityDecision.restore(
                status: "unknown",
                reason: nil,
                inspectorVersion: MediaCapabilityInspector.version
            )
        )
    }

    func testCapabilityDecisionsNeverPromoteUncertainSources() {
        XCTAssertEqual(
            MediaEligibilityClassifier.apply(.supported),
            .capabilitiesInspected
        )
        XCTAssertEqual(
            MediaEligibilityClassifier.apply(.unsupported("HDR")),
            .unsupported("HDR")
        )
        XCTAssertEqual(
            MediaEligibilityClassifier.apply(.uncertain("Color metadata missing")),
            .uncertain("Color metadata missing")
        )
    }

}

private extension MediaCapabilityInspectorTests {
    private func imageCapabilities(
        frameCount: Int = 1,
        hasAlpha: Bool? = false,
        bitDepth: Int? = 8,
        colorProfile: String? = "sRGB IEC61966-2.1",
        exifColorSpace: Int? = nil,
        auxiliaryDataTypes: [String] = []
    ) -> ImageSourceCapabilities {
        ImageSourceCapabilities(
            typeIdentifier: "public.jpeg",
            frameCount: frameCount,
            hasAlpha: hasAlpha,
            bitDepth: bitDepth,
            colorProfile: colorProfile,
            exifColorSpace: exifColorSpace,
            auxiliaryDataTypes: auxiliaryDataTypes
        )
    }

    private func videoCapabilities(
        isPlayable: Bool = true,
        hasValidDuration: Bool = true,
        videoTrackCount: Int = 1,
        audioTrackCount: Int = 1,
        otherTrackCount: Int = 0,
        videoCodecType: FourCharCode? = kCMVideoCodecType_H264,
        colorPrimaries: String? = "ITU_R_709_2",
        transferFunction: String? = "ITU_R_709_2",
        logTransferFunction: String? = nil
    ) -> VideoSourceCapabilities {
        VideoSourceCapabilities(
            isPlayable: isPlayable,
            hasValidDuration: hasValidDuration,
            videoTrackCount: videoTrackCount,
            audioTrackCount: audioTrackCount,
            otherTrackCount: otherTrackCount,
            videoCodecType: videoCodecType,
            colorPrimaries: colorPrimaries,
            transferFunction: transferFunction,
            logTransferFunction: logTransferFunction
        )
    }
}
