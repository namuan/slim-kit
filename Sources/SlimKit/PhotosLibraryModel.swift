import Foundation
import Observation
import Photos

@MainActor
@Observable
final class PhotosLibraryModel: NSObject, PHPhotoLibraryChangeObserver {
    private(set) var accessState = PhotosAccessState(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    private(set) var assets: [MediaAsset] = []
    private(set) var isLoading = false
    private(set) var scannedAssetCount = 0
    private(set) var totalAssetCount = 0
    private(set) var errorMessage: String?
    private var scanTask: Task<Void, Never>?
    private var scanID = UUID()

    override init() {
        super.init()
        PHPhotoLibrary.shared().register(self)
        AppLogger.shared.info("Photos", "Observer registered; authorization=\(accessState.logLabel)")
        refreshAssets()
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        AppLogger.shared.info("Photos", "Observer unregistered")
    }

    func connect() {
        errorMessage = nil
        AppLogger.shared.info("Authorization", "User requested read-write Photos access")
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.accessState = PhotosAccessState(status)
                AppLogger.shared.info("Authorization", "Request completed; status=\(self.accessState.logLabel)")
                self.refreshAssets()
            }
        }
    }

    func refreshAuthorization() {
        let currentState = PhotosAccessState(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        guard currentState != accessState else {
            AppLogger.shared.debug("Authorization", "Foreground recheck unchanged; status=\(currentState.logLabel)")
            return
        }
        accessState = currentState
        AppLogger.shared.info("Authorization", "Foreground access changed; status=\(accessState.logLabel)")
        refreshAssets()
    }

    func refreshAssets() {
        accessState = PhotosAccessState(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        scanTask?.cancel()
        scanTask = nil
        scanID = UUID()
        assets = []
        scannedAssetCount = 0
        totalAssetCount = 0
        guard accessState.canRead else {
            isLoading = false
            AppLogger.shared.warning("PhotosScan", "Skipped scan; authorization=\(accessState.logLabel)")
            return
        }

        let currentScanID = scanID
        isLoading = true
        errorMessage = nil
        AppLogger.shared.info("PhotosScan", "Started; sorting=creationDate descending; scanID=\(currentScanID.uuidString)")
        let model = self
        scanTask = Task.detached(priority: .userInitiated) { [model] in
            let queryStart = ContinuousClock.now
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let result = PHAsset.fetchAssets(with: options)
            let total = result.count
            let queryDuration = queryStart.duration(to: .now)
            AppLogger.shared.info(
                "PhotosScan",
                "Fetch query completed; assets=\(total); duration=\(queryDuration.formatted())"
            )
            await MainActor.run {
                guard model.scanID == currentScanID else { return }
                model.totalAssetCount = total
            }

            var batch: [MediaAsset] = []
            batch.reserveCapacity(1_000)
            var processed = 0
            var photos = 0
            var videos = 0
            let enumerationStart = ContinuousClock.now
            for index in 0..<result.count {
                guard !Task.isCancelled else { break }
                let asset = result.object(at: index)
                guard asset.mediaType == .image || asset.mediaType == .video else { continue }
                let mediaAsset = MediaAsset(asset: asset)
                batch.append(mediaAsset)
                processed += 1
                if mediaAsset.kind == .photo {
                    photos += 1
                } else {
                    videos += 1
                }
                if batch.count == 1_000 {
                    let nextBatch = batch
                    batch.removeAll(keepingCapacity: true)
                    let completedCount = processed
                    await MainActor.run {
                        guard model.scanID == currentScanID else { return }
                        model.assets.append(contentsOf: nextBatch)
                        model.scannedAssetCount = completedCount
                    }
                }
                if processed > 0, processed.isMultiple(of: 5_000) {
                    AppLogger.shared.info(
                        "PhotosScan",
                        "Enumeration progress; processed=\(processed); total=\(total); photos=\(photos); videos=\(videos)"
                    )
                }
            }

            guard !Task.isCancelled else {
                AppLogger.shared.info("PhotosScan", "Cancelled; processed=\(processed); total=\(total)")
                return
            }
            let finalBatch = batch
            let enumerationDuration = enumerationStart.duration(to: .now)
            let finalProcessedCount = processed
            await MainActor.run {
                guard model.scanID == currentScanID else { return }
                model.assets.append(contentsOf: finalBatch)
                model.scannedAssetCount = finalProcessedCount
                model.isLoading = false
                model.scanTask = nil
            }
            AppLogger.shared.info(
                "PhotosScan",
                "Completed; processed=\(processed); photos=\(photos); videos=\(videos); duration=\(enumerationDuration.formatted())"
            )
        }
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        AppLogger.shared.info("Photos", "Library change notification received")
        Task { @MainActor [weak self] in
            self?.refreshAssets()
        }
    }
}

private extension PhotosAccessState {
    var logLabel: String {
        switch self {
        case .notDetermined: "notDetermined"
        case .authorized: "authorized"
        case .limited: "limited"
        case .denied: "denied"
        case .restricted: "restricted"
        }
    }
}
