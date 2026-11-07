import AVFoundation
import Foundation
import XCTest
@testable import SlimKit

extension MediaCapabilityInspectorTests {
    func testImageInspectorRejectsEncodedAlphaPNG() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try createAlphaPNG(at: url)

        XCTAssertEqual(
            MediaCapabilityInspector.inspectImage(at: url),
            .unsupported("Transparent images are not supported by the current output policy.")
        )
    }

    func testImageInspectorRejectsEncodedAnimatedGIF() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        try createAnimatedGIF(at: url)

        XCTAssertEqual(
            MediaCapabilityInspector.inspectImage(at: url),
            .unsupported("Multi-frame or animated images are not supported.")
        )
    }

    func testVideoInspectorReadsGeneratedSDRVideo() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await createVideo(at: url)

        let decision = await MediaCapabilityInspector.inspectVideo(at: url)
        XCTAssertEqual(decision, .supported)
    }

    func testVideoInspectorRejectsEncodedHDRVideo() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-hdr.mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await createVideo(
            at: url,
            colorPrimaries: AVVideoColorPrimaries_ITU_R_2020,
            transferFunction: AVVideoTransferFunction_SMPTE_ST_2084_PQ
        )

        let decision = await MediaCapabilityInspector.inspectVideo(at: url)
        XCTAssertEqual(
            decision,
            .unsupported("Wide-gamut video is not supported by the current output policy.")
        )
    }

    func testVideoInspectorRejectsEncodedMultipleVideoTracks() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-tracks.mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await createVideo(at: url, videoTrackCount: 2)

        let decision = await MediaCapabilityInspector.inspectVideo(at: url)
        XCTAssertEqual(decision, .unsupported("The video must contain exactly one video track."))
    }
}
