import AVKit
import AppKit
import Photos
import SwiftUI

struct MediaPreviewView: View {
    let asset: MediaAsset
    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var playerItemStatus: Int?
    @State private var playerItemError: String?
    @State private var requestID: PHImageRequestID?
    @State private var requestToken = UUID()
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var needsNetworkConsent = false
    @State private var networkAccessAllowed = false
    @State private var downloadProgress: Double?
    @State private var showingNetworkConfirmation = false

    var body: some View {
        Group {
            if let player {
                if playerItemStatus == AVPlayerItem.Status.failed.rawValue {
                    ContentUnavailableView(
                        "Unable to Play Video",
                        systemImage: "video.slash",
                        description: Text(playerItemError ?? "Photos returned a video that the player cannot play.")
                    )
                } else {
                    ZStack {
                        NativeVideoPlayer(
                            player: player,
                            itemStatus: $playerItemStatus,
                            itemError: $playerItemError
                        )
                        if playerItemStatus == nil || playerItemStatus == AVPlayerItem.Status.unknown.rawValue {
                            ProgressView("Preparing video…")
                                .padding(12)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else if isLoading {
                VStack(spacing: 14) {
                    if networkAccessAllowed, let downloadProgress {
                        ProgressView(value: downloadProgress) {
                            Text("Downloading original from iCloud · \(Int(downloadProgress * 100))%")
                        }
                    } else {
                        ProgressView(networkAccessAllowed ? "Downloading original from iCloud…" : "Loading preview…")
                    }
                    if networkAccessAllowed {
                        Button("Cancel Download", role: .cancel, action: cancelPreviewDownload)
                    }
                }
            } else if needsNetworkConsent {
                iCloudPreviewPrompt
            } else {
                unavailablePreview
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.04))
        .task {
            requestPreview()
        }
        .onDisappear(perform: cancelPreviewRequest)
        .alert("Download original from iCloud?", isPresented: $showingNetworkConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Download & Preview") {
                networkAccessAllowed = true
                requestPreview()
            }
        } message: {
            Text(
                "This may use network data. SlimKit will only read the original; " +
                    "your Photos library will not be changed."
            )
        }
    }

    private var iCloudPreviewPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("This original is in iCloud")
                .font(.title2.weight(.semibold))
            Text(
                "It must be downloaded to preview. This may use network data; " +
                    "SlimKit will not change your Photos library."
            )
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            Button("Download & Preview") {
                showingNetworkConfirmation = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }

    private var unavailablePreview: some View {
        VStack(spacing: 12) {
            ContentUnavailableView(
                "Preview Unavailable",
                systemImage: asset.kind == .video ? "video.slash" : "photo.slash",
                description: Text(errorMessage ?? "Photos did not provide a preview.")
            )
            if errorMessage != nil {
                Button("Try Again", action: requestPreview)
            }
        }
    }

}

private extension MediaPreviewView {
    func requestPreview() {
        cancelCurrentRequest()
        guard !PhotosRuntimeEnvironment.isRunningTests else {
            finishWithError("Photo previews are disabled in the test host.", requestToken: requestToken)
            return
        }
        let token = UUID()
        requestToken = token
        downloadProgress = nil
        isLoading = true
        needsNetworkConsent = false
        errorMessage = nil
        AppLogger.shared.info(
            "Preview",
            "Request started; mediaType=\(asset.kind.rawValue); networkAccess=\(networkAccessAllowed)"
        )
        let fetchedAssets = PHAsset.fetchAssets(withLocalIdentifiers: [asset.id], options: nil)
        guard let photoAsset = fetchedAssets.firstObject else {
            finishWithError("The Photos item is no longer accessible.", requestToken: token)
            return
        }
        switch asset.kind {
        case .photo:
            requestImage(for: photoAsset, requestToken: token)
        case .video:
            requestVideo(for: photoAsset, requestToken: token)
        }
    }

    func requestImage(for photoAsset: PHAsset, requestToken: UUID) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = networkAccessAllowed
        if networkAccessAllowed {
            options.progressHandler = { progress, _, _, _ in
                Task { @MainActor in
                    guard self.requestToken == requestToken else { return }
                    downloadProgress = progress
                }
            }
        }
        self.requestID = PHImageManager.default().requestImage(
            for: photoAsset,
            targetSize: CGSize(width: 2_400, height: 2_400),
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            if let error = info?[PHImageErrorKey] as? Error {
                Task { @MainActor in
                    handleRequestError(error, requestToken: requestToken)
                }
                return
            }
            if info?[PHImageCancelledKey] as? Bool == true {
                Task { @MainActor in
                    finishWithError("The preview request was cancelled.", requestToken: requestToken)
                }
                return
            }
            if info?[PHImageResultIsInCloudKey] as? Bool == true, image == nil {
                Task { @MainActor in
                    requireNetworkAccess(requestToken: requestToken)
                }
                return
            }
            guard let image else {
                Task { @MainActor in
                    finishWithError("Photos did not provide a local preview.", requestToken: requestToken)
                }
                return
            }
            Task { @MainActor in
                guard self.requestToken == requestToken else { return }
                self.requestID = nil
                self.image = image
                isLoading = false
                AppLogger.shared.info("Preview", "Image preview completed")
            }
        }
    }

    func requestVideo(for photoAsset: PHAsset, requestToken: UUID) {
        let options = PHVideoRequestOptions()
        options.deliveryMode = .automatic
        options.isNetworkAccessAllowed = networkAccessAllowed
        if networkAccessAllowed {
            options.progressHandler = { progress, _, _, _ in
                Task { @MainActor in
                    guard self.requestToken == requestToken else { return }
                    downloadProgress = progress
                }
            }
        }
        self.requestID = PHImageManager.default().requestPlayerItem(
            forVideo: photoAsset,
            options: options
        ) { item, info in
            Task { @MainActor in
                handleVideoResult(item, info: info, requestToken: requestToken)
            }
        }
    }

    func handleVideoResult(_ item: AVPlayerItem?, info: [AnyHashable: Any]?, requestToken: UUID) {
        guard self.requestToken == requestToken else { return }
        if let error = info?[PHImageErrorKey] as? Error {
            handleRequestError(error, requestToken: requestToken)
            return
        }
        if info?[PHImageCancelledKey] as? Bool == true {
            finishWithError("The preview request was cancelled.", requestToken: requestToken)
            return
        }
        if info?[PHImageResultIsInCloudKey] as? Bool == true, item == nil {
            requireNetworkAccess(requestToken: requestToken)
            return
        }
        guard let item else {
            finishWithError("Photos did not provide a local video preview.", requestToken: requestToken)
            return
        }
        requestID = nil
        player = AVPlayer(playerItem: item)
        playerItemStatus = item.status.rawValue
        playerItemError = item.error?.localizedDescription
        isLoading = false
        AppLogger.shared.info("Preview", "Video player item received; status=\(item.status.rawValue)")
    }

    func handleRequestError(_ error: Error, requestToken: UUID) {
        guard self.requestToken == requestToken else { return }
        let photosError = error as NSError
        if photosError.domain == PHPhotosErrorDomain,
           photosError.code == PHPhotosError.networkAccessRequired.rawValue {
            if networkAccessAllowed {
                finishWithError(
                    "Photos could not download this original from iCloud. Check the network connection and try again.",
                    requestToken: requestToken
                )
            } else {
                requireNetworkAccess(requestToken: requestToken)
            }
        } else {
            finishWithError(error.localizedDescription, requestToken: requestToken)
        }
    }

    func requireNetworkAccess(requestToken: UUID) {
        guard self.requestToken == requestToken else { return }
        requestID = nil
        downloadProgress = nil
        isLoading = false
        needsNetworkConsent = true
        AppLogger.shared.info("Preview", "iCloud download requires user confirmation")
    }

    func finishWithError(_ message: String, requestToken: UUID) {
        guard self.requestToken == requestToken else { return }
        requestID = nil
        downloadProgress = nil
        errorMessage = message
        isLoading = false
        needsNetworkConsent = false
        AppLogger.shared.warning("Preview", "Request failed; error=\(message)")
    }

    func cancelPreviewDownload() {
        requestToken = UUID()
        cancelCurrentRequest()
        networkAccessAllowed = false
        finishWithError("The download was cancelled. Your Photos library was not changed.", requestToken: requestToken)
    }

    func cancelPreviewRequest() {
        requestToken = UUID()
        cancelCurrentRequest()
        player?.pause()
        player = nil
    }

    func cancelCurrentRequest() {
        guard let requestID else { return }
        self.requestID = nil
        guard !PhotosRuntimeEnvironment.isRunningTests else { return }
        PHImageManager.default().cancelImageRequest(requestID)
        AppLogger.shared.info("Preview", "PhotoKit request cancelled")
    }
}

private struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer
    @Binding var itemStatus: Int?
    @Binding var itemError: String?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.allowsVideoFrameAnalysis = false
        view.updatesNowPlayingInfoCenter = false
        updateCoordinator(context.coordinator)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
        updateCoordinator(context.coordinator)
    }

    private func updateCoordinator(_ coordinator: Coordinator) {
        coordinator.statusChanged = { status, error in
            itemStatus = status
            itemError = error
        }
        coordinator.observe(player.currentItem)
    }

    final class Coordinator {
        private var statusObservation: NSKeyValueObservation?
        private weak var observedItem: AVPlayerItem?
        var statusChanged: ((Int?, String?) -> Void)?

        func observe(_ item: AVPlayerItem?) {
            guard observedItem !== item else { return }
            statusObservation?.invalidate()
            observedItem = item
            guard let item else {
                statusChanged?(nil, nil)
                return
            }
            statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                let status = item.status
                let statusValue = status.rawValue
                let error = item.error?.localizedDescription
                let duration = CMTimeGetSeconds(item.duration)
                if status == .readyToPlay {
                    AppLogger.shared.info("Preview", "Video player ready; duration=\(duration)")
                } else if status == .failed {
                    AppLogger.shared.error("Preview", "Video player failed; error=\(error ?? "unknown")")
                }
                Task { @MainActor [weak self] in
                    self?.statusChanged?(statusValue, error)
                }
            }
        }
    }
}
