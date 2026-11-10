import AppKit
import SwiftUI
import XCTest
@testable import SlimKit

final class MediaBrowserLayoutTests: XCTestCase {
    func testGridFitsPaneAcrossWidthsAndThumbnailSizes() {
        for width in stride(from: 280.0, through: 1_600.0, by: 20) {
            for preferred in stride(from: 190.0, through: 320.0, by: 10) {
                let layout = MediaGridLayout(availableWidth: width, preferredWidth: preferred)
                let occupied = CGFloat(layout.columnCount) * layout.cardWidth
                    + CGFloat(layout.columnCount - 1) * MediaGridLayout.spacing
                    + 2 * MediaGridLayout.horizontalPadding
                XCTAssertEqual(occupied, width, accuracy: 0.01)
                XCTAssertGreaterThanOrEqual(layout.columnCount, 1)
                XCTAssertGreaterThanOrEqual(layout.cardWidth, min(preferred, width - 40))
                XCTAssertEqual(layout.thumbnailHeight, layout.cardWidth * 0.75, accuracy: 0.01)
            }
        }
    }

    func testLargerThumbnailsReduceColumnCount() {
        let small = MediaGridLayout(availableWidth: 900, preferredWidth: 190)
        let large = MediaGridLayout(availableWidth: 900, preferredWidth: 320)
        XCTAssertEqual(small.columnCount, 4)
        XCTAssertEqual(large.columnCount, 2)
        XCTAssertGreaterThan(large.thumbnailHeight, small.thumbnailHeight)
    }

    func testGridClampsStalePreferences() {
        for preferred in [-100.0, 0, Double.nan, Double.infinity, 10_000] {
            let layout = MediaGridLayout(availableWidth: 500, preferredWidth: preferred)
            XCTAssertTrue(layout.cardWidth.isFinite)
            XCTAssertGreaterThan(layout.cardWidth, 0)
            XCTAssertGreaterThanOrEqual(layout.columnCount, 1)
        }
    }

    @MainActor
    func testLoadedThumbnailsCannotChangeFrameSize() throws {
        for imageSize in [NSSize(width: 48, height: 400), NSSize(width: 900, height: 120)] {
            let image = fixtureImage(size: imageSize)
            for width in [190.0, 230, 320, 460] {
                let renderer = ImageRenderer(content: MediaThumbnail(
                    image: image,
                    height: width * 0.75,
                    isVideo: true,
                    durationText: "11:04",
                    isSelected: true
                ).frame(width: width).fixedSize(horizontal: false, vertical: true))
                let rendered = try XCTUnwrap(renderer.nsImage)
                XCTAssertEqual(rendered.size.width, width, accuracy: 1)
                XCTAssertEqual(rendered.size.height, width * 0.75, accuracy: 1)
            }
        }
    }

    @MainActor
    func testCardHeightRemainsBoundedForPhotoAndVideo() throws {
        for kind in [MediaAsset.Kind.photo, .video] {
            for width in [190.0, 230, 320, 460] {
                let renderer = ImageRenderer(content: card(index: 0, kind: kind, width: width)
                    .frame(width: width)
                    .fixedSize(horizontal: false, vertical: true))
                let image = try XCTUnwrap(renderer.nsImage)
                XCTAssertEqual(image.size.width, width, accuracy: 1)
                XCTAssertGreaterThan(image.size.height, width * 0.75 + 40)
                XCTAssertLessThan(image.size.height, width * 0.75 + 110)
            }
        }
    }

    @MainActor
    func testHeaderFitsNarrowAndWidePanes() throws {
        for width in [320.0, 500, 900] {
            let renderer = ImageRenderer(content: header
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true))
            let image = try XCTUnwrap(renderer.nsImage)
            XCTAssertEqual(image.size.width, width, accuracy: 1)
            XCTAssertLessThan(image.size.height, 220)
        }
    }

    @MainActor
    func testRenderSyntheticBrowserAtNarrowAndWideWidths() async throws {
        for width in [500.0, 900] {
            let browser = VStack(spacing: 0) {
                header
                Divider()
                MediaBrowserGrid(preferredWidth: 230) { layout in
                    ForEach(0..<12) { index in
                        VStack(alignment: .leading, spacing: 7) {
                            MediaThumbnail(
                                image: self.fixtureImage(size: NSSize(
                                    width: index.isMultiple(of: 2) ? 900 : 48, height: 400
                                )),
                                height: layout.thumbnailHeight,
                                isVideo: index.isMultiple(of: 2),
                                durationText: "0:11",
                                isSelected: index == 0
                            )
                            Text("8 Nov 2026").font(.caption)
                            Text("2.3 MB · verified").font(.caption2).foregroundStyle(.secondary)
                            Text("Needs source inspection").font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(2, reservesSpace: true)
                        }
                    }
                }
            }
            .frame(width: width, height: 760)
            .background(Color(nsColor: .windowBackgroundColor))
            let hostingView = NSHostingView(rootView: browser)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 760),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.contentView = hostingView
            hostingView.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            hostingView.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
            hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
            let image = NSImage(size: NSSize(width: width, height: 760))
            image.addRepresentation(bitmap)
            XCTAssertGreaterThan(coloredPixelCount(bitmap), 100)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Browser-\(Int(width))"
            attachment.lifetime = .keepAlways
            add(attachment)
            window.contentView = nil
        }
    }

    private func coloredPixelCount(_ bitmap: NSBitmapImageRep) -> Int {
        var count = 0
        for pixelX in stride(from: 0, to: bitmap.pixelsWide, by: 10) {
            for pixelY in stride(from: 0, to: bitmap.pixelsHigh, by: 10) {
                if let color = bitmap.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.deviceRGB),
                   color.saturationComponent > 0.3 {
                    count += 1
                }
            }
        }
        return count
    }

    @MainActor
    private var header: some View {
        MediaBrowserHeader(
            title: "All Media",
            summary: "23,035 items · 18 sizes verified",
            sortOrder: .constant(.newest),
            thumbnailMinimumWidth: .constant(230)
        )
    }

    @MainActor
    private func card(index: Int, kind: MediaAsset.Kind, width: CGFloat) -> some View {
        MediaCard(
            asset: MediaAsset(
                id: "fixture-\(index)", kind: kind, creationDate: .distantPast, modificationDate: .distantPast,
                pixelWidth: 900, pixelHeight: 400, duration: kind == .video ? 11 : nil,
                isFavorite: false, eligibility: .pendingInspection
            ),
            sizeLabel: "2.3 MB · verified",
            thumbnailHeight: width * 0.75,
            isSelected: true,
            isKept: false,
            onSelect: {}, onKeep: {}, onPreview: {}
        )
    }

    @MainActor
    private func fixtureImage(size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            NSColor.systemIndigo.setFill()
            NSRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height).fill()
            return true
        }
    }
}
