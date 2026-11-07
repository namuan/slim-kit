import AppKit
import Photos
import SwiftUI

struct MediaCard: View {
    let asset: MediaAsset
    let sizeLabel: String
    let isSelected: Bool
    let isKept: Bool
    let onSelect: () -> Void
    let onKeep: () -> Void
    let onPreview: () -> Void
    @State private var thumbnail: NSImage?
    @State private var thumbnailRequestID: PHImageRequestID?
    @State private var thumbnailRequestToken = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button(action: onSelect) {
                ZStack(alignment: .topTrailing) {
                    thumbnailContent
                        .frame(height: 150)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    if asset.kind == .video {
                        Label(durationText, systemImage: "play.fill")
                            .font(.caption2.weight(.semibold))
                            .padding(6)
                            .background(.black.opacity(0.68), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(7)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(isSelected ? .white : .white, isSelected ? .blue : .black.opacity(0.45))
                        .padding(7)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Preview", systemImage: "eye", action: onPreview)
                Button(
                    isKept ? "Remove from Kept" : "Keep for Review",
                    systemImage: isKept ? "bookmark.slash" : "bookmark",
                    action: onKeep
                )
            }
            HStack(spacing: 5) {
                Text(asset.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? "Date unknown")
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isKept {
                    Image(systemName: "bookmark.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(sizeLabel)
                .font(.caption2)
                .foregroundStyle(sizeLabel.contains("verified") ? .secondary : .tertiary)
            Text(eligibilitySummary)
                .font(.caption2)
                .foregroundStyle(asset.eligibility.isUnsupported ? .orange : .secondary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
        .task(id: asset.id) {
            loadThumbnail()
        }
        .onDisappear(perform: cancelThumbnailRequest)
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .scaledToFill()
        } else {
            Rectangle()
                .fill(.quaternary)
                .overlay {
                    Image(systemName: asset.kind == .video ? "video" : "photo")
                        .foregroundStyle(.secondary)
                }
        }
    }

    private var eligibilitySummary: String {
        switch asset.eligibility {
        case .pendingInspection:
            "Eligibility not inspected"
        case .inspectImageSource, .inspectVideoSource:
            "Needs source inspection"
        case let .unsupported(reason):
            "Unsupported · \(reason)"
        case let .unavailable(reason):
            "Unavailable · \(reason)"
        }
    }

    private var durationText: String {
        guard let duration = asset.duration else { return "Video" }
        let seconds = Int(duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func loadThumbnail() {
        cancelThumbnailRequest()
        thumbnail = nil
        let requestToken = UUID()
        thumbnailRequestToken = requestToken
        AppLogger.shared.debug("Thumbnail", "Request started; mediaType=\(asset.kind.rawValue); networkAccess=false")
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [asset.id], options: nil)
        guard let photoAsset = result.firstObject else {
            AppLogger.shared.warning("Thumbnail", "Request skipped; asset is no longer accessible")
            return
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        thumbnailRequestID = PHImageManager.default().requestImage(
            for: photoAsset,
            targetSize: CGSize(width: 420, height: 300),
            contentMode: .aspectFill,
            options: options
        ) { image, info in
            if let error = info?[PHImageErrorKey] as? Error {
                AppLogger.shared.error("Thumbnail", "Request failed; error=\(error.localizedDescription)")
                return
            }
            if info?[PHImageCancelledKey] as? Bool == true {
                AppLogger.shared.info("Thumbnail", "Request cancelled")
                return
            }
            guard let image else { return }
            if info?[PHImageResultIsDegradedKey] as? Bool != true {
                AppLogger.shared.debug("Thumbnail", "Request completed; mediaType=\(asset.kind.rawValue)")
            }
            Task { @MainActor in
                guard thumbnailRequestToken == requestToken else { return }
                thumbnail = image
            }
        }
    }

    private func cancelThumbnailRequest() {
        thumbnailRequestToken = UUID()
        guard let thumbnailRequestID else { return }
        AppLogger.shared.debug("Thumbnail", "Request cancelled because its card left the visible grid")
        PHImageManager.default().cancelImageRequest(thumbnailRequestID)
        self.thumbnailRequestID = nil
    }
}
