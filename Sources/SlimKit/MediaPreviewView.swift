import AVKit
import AppKit
import Photos
import SwiftUI

struct MediaPreviewView: View {
    let asset: MediaAsset
    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var requestID: PHImageRequestID?
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let player {
                NativeVideoPlayer(player: player)
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else if isLoading {
                ProgressView("Loading preview…")
            } else {
                ContentUnavailableView(
                    "Preview Unavailable",
                    systemImage: asset.kind == .video ? "video.slash" : "photo.slash",
                    description: Text(errorMessage ?? "The media is not available on this Mac.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.04))
        .task {
            requestPreview()
        }
        .onDisappear(perform: cancelPreviewRequest)
    }

    private func requestPreview() {
        AppLogger.shared.info("Preview", "Request started; mediaType=\(asset.kind.rawValue); networkAccess=false")
        let fetchedAssets = PHAsset.fetchAssets(withLocalIdentifiers: [asset.id], options: nil)
        guard let photoAsset = fetchedAssets.firstObject else {
            finishWithError("The Photos item is no longer accessible.")
            return
        }
        switch asset.kind {
        case .photo:
            requestImage(for: photoAsset)
        case .video:
            requestVideo(for: photoAsset)
        }
    }

    private func requestImage(for photoAsset: PHAsset) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        requestID = PHImageManager.default().requestImage(
            for: photoAsset,
            targetSize: CGSize(width: 2_400, height: 2_400),
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            if let error = info?[PHImageErrorKey] as? Error {
                Task { @MainActor in
                    finishWithError(error.localizedDescription)
                }
                return
            }
            if info?[PHImageCancelledKey] as? Bool == true {
                Task { @MainActor in
                    finishWithError("The preview request was cancelled.")
                }
                return
            }
            if info?[PHImageResultIsInCloudKey] as? Bool == true, image == nil {
                Task { @MainActor in
                    finishWithError("This original is stored in iCloud and is not downloaded on this Mac.")
                }
                return
            }
            guard let image else {
                Task { @MainActor in
                    finishWithError("Photos did not provide a local preview.")
                }
                return
            }
            Task { @MainActor in
                self.image = image
                isLoading = false
                AppLogger.shared.info("Preview", "Image preview completed")
            }
        }
    }

    private func requestVideo(for photoAsset: PHAsset) {
        let options = PHVideoRequestOptions()
        options.deliveryMode = .automatic
        options.isNetworkAccessAllowed = false
        requestID = PHImageManager.default().requestPlayerItem(forVideo: photoAsset, options: options) { item, info in
            if let error = info?[PHImageErrorKey] as? Error {
                Task { @MainActor in
                    finishWithError(error.localizedDescription)
                }
                return
            }
            if info?[PHImageCancelledKey] as? Bool == true {
                Task { @MainActor in
                    finishWithError("The preview request was cancelled.")
                }
                return
            }
            if info?[PHImageResultIsInCloudKey] as? Bool == true, item == nil {
                Task { @MainActor in
                    finishWithError("This original is stored in iCloud and is not downloaded on this Mac.")
                }
                return
            }
            guard let item else {
                Task { @MainActor in
                    finishWithError("Photos did not provide a local video preview.")
                }
                return
            }
            Task { @MainActor in
                player = AVPlayer(playerItem: item)
                isLoading = false
                AppLogger.shared.info("Preview", "Video preview completed")
            }
        }
    }

    private func cancelPreviewRequest() {
        if let requestID {
            PHImageManager.default().cancelImageRequest(requestID)
            AppLogger.shared.info("Preview", "Request cancelled because preview closed")
        }
        player?.pause()
        player = nil
        requestID = nil
    }

    private func finishWithError(_ message: String) {
        errorMessage = message
        isLoading = false
        AppLogger.shared.warning("Preview", "Request failed; error=\(message)")
    }
}

private struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.allowsVideoFrameAnalysis = false
        view.updatesNowPlayingInfoCenter = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }
}
