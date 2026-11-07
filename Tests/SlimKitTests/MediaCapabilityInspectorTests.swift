import CoreGraphics
import CoreMedia
import ImageIO
import UniformTypeIdentifiers
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

    func testUnknownVideoColorMetadataIsUncertain() {
        XCTAssertEqual(
            MediaCapabilityInspector.assessVideo(
                videoCapabilities(colorPrimaries: nil)
            ),
            .uncertain("Video color metadata is missing.")
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

    private func createSRGBJPEG(at url: URL) throws {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        )
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        )
        let properties: [String: Any] = [
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifColorSpace as String: 1
            ]
        ]
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

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
