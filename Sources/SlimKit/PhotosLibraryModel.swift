import Foundation
import Observation
import Photos

@MainActor
@Observable
final class PhotosLibraryModel: NSObject, PHPhotoLibraryChangeObserver {
    private(set) var accessState: PhotosAccessState = {
        guard !PhotosRuntimeEnvironment.isRunningTests else { return .restricted }
        return PhotosAccessState(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }()
    private(set) var assets: [MediaAsset] = []
    private(set) var isLoading = false
    private(set) var scannedAssetCount = 0
    private(set) var totalAssetCount = 0
    private(set) var errorMessage: String?
    private var scanTask: Task<Void, Never>?
    private var libraryChangeTask: Task<Void, Never>?
    private var scanID = UUID()

    override init() {
        super.init()
        guard !PhotosRuntimeEnvironment.isRunningTests else {
            AppLogger.shared.info("Photos", "Library model disabled in unit test host")
            return
        }
        PHPhotoLibrary.shared().register(self)
        AppLogger.shared.info("Photos", "Observer registered; authorization=\(accessState.logLabel)")
        refreshAssets()
    }

    deinit {
        guard !PhotosRuntimeEnvironment.isRunningTests else { return }
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        AppLogger.shared.info("Photos", "Observer unregistered")
    }

    func connect() {
        guard !PhotosRuntimeEnvironment.isRunningTests else { return }
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
        guard !PhotosRuntimeEnvironment.isRunningTests else { return }
        let currentState = PhotosAccessState(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        guard currentState != accessState else {
            AppLogger.shared.debug("Authorization", "Foreground recheck unchanged; status=\(currentState.logLabel)")
            return
        }
        accessState = currentState
        AppLogger.shared.info("Authorization", "Foreground access changed; status=\(accessState.logLabel)")
        refreshAssets()
    }

    func updateEligibility(_ eligibility: MediaEligibility, for identifier: String) {
        guard let index = assets.firstIndex(where: { $0.id == identifier }) else { return }
        assets[index].eligibility = eligibility
    }

    func applyCapabilityDecision(_ decision: MediaCapabilityDecision, for identifier: String) {
        updateEligibility(MediaEligibilityClassifier.apply(decision), for: identifier)
    }

    func refreshAssets() {
        guard !PhotosRuntimeEnvironment.isRunningTests else {
            accessState = .restricted
            isLoading = false
            assets = []
            return
        }
        libraryChangeTask?.cancel()
        libraryChangeTask = nil
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
        isLoading = true
        errorMessage = nil
        AppLogger.shared.info("PhotosScan", "Started; sorting=creationDate descending; scanID=\(scanID.uuidString)")
        startScan(scanID: scanID)
    }

    private func startScan(scanID: UUID) {
        let model = self
        scanTask = Task.detached(priority: .userInitiated) {
            await Self.scan(scanID: scanID, model: model)
        }
    }

    nonisolated private static func scan(scanID: UUID, model: PhotosLibraryModel) async {
        let queryStart = ContinuousClock.now
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: options)
        let queryDuration = queryStart.duration(to: .now)
        AppLogger.shared.info(
            "PhotosScan",
            "Fetch query completed; assets=\(result.count); duration=\(queryDuration.formatted())"
        )
        await model.setTotalAssetCount(result.count, scanID: scanID)
        let enumerationStart = ContinuousClock.now
        let counts = await enumerate(result, scanID: scanID, model: model)
        guard !Task.isCancelled else {
            AppLogger.shared.info("PhotosScan", "Cancelled; processed=\(counts.processed); total=\(result.count)")
            return
        }
        let duration = enumerationStart.duration(to: .now)
        await model.finishScan(scanID: scanID, processedCount: counts.processed)
        AppLogger.shared.info(
            "PhotosScan",
            "Completed; processed=\(counts.processed); photos=\(counts.photos); videos=\(counts.videos); " +
                "duration=\(duration.formatted())"
        )
    }

    nonisolated private static func enumerate(
        _ result: PHFetchResult<PHAsset>,
        scanID: UUID,
        model: PhotosLibraryModel
    ) async -> AssetScanCounts {
        var counts = AssetScanCounts()
        var batch: [MediaAsset] = []
        batch.reserveCapacity(1_000)
        for index in 0..<result.count {
            guard !Task.isCancelled else { break }
            let asset = result.object(at: index)
            guard asset.mediaType == .image || asset.mediaType == .video else { continue }
            let mediaAsset = MediaAsset(asset: asset)
            batch.append(mediaAsset)
            counts.include(mediaAsset.kind)
            if batch.count == 1_000 {
                await model.appendBatch(batch, processedCount: counts.processed, scanID: scanID)
                batch.removeAll(keepingCapacity: true)
            }
            if counts.processed > 0, counts.processed.isMultiple(of: 5_000) {
                AppLogger.shared.info(
                    "PhotosScan",
                    "Enumeration progress; processed=\(counts.processed); total=\(result.count); " +
                        "photos=\(counts.photos); videos=\(counts.videos)"
                )
            }
        }
        if !Task.isCancelled, !batch.isEmpty {
            await model.appendBatch(batch, processedCount: counts.processed, scanID: scanID)
        }
        return counts
    }

    private func setTotalAssetCount(_ count: Int, scanID: UUID) {
        guard self.scanID == scanID else { return }
        totalAssetCount = count
    }

    private func appendBatch(_ batch: [MediaAsset], processedCount: Int, scanID: UUID) {
        guard self.scanID == scanID else { return }
        assets.append(contentsOf: batch)
        scannedAssetCount = processedCount
    }

    private func finishScan(scanID: UUID, processedCount: Int) {
        guard self.scanID == scanID else { return }
        scannedAssetCount = processedCount
        isLoading = false
        scanTask = nil
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        AppLogger.shared.info("Photos", "Library change notification received")
        Task { @MainActor [weak self] in
            self?.scheduleLibraryRefresh()
        }
    }

    private func scheduleLibraryRefresh() {
        libraryChangeTask?.cancel()
        libraryChangeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            libraryChangeTask = nil
            AppLogger.shared.info("PhotosScan", "Debounced library change; refreshing assets")
            refreshAssets()
        }
    }
}

private struct AssetScanCounts {
    private(set) var processed = 0
    private(set) var photos = 0
    private(set) var videos = 0

    mutating func include(_ kind: MediaAsset.Kind) {
        processed += 1
        if kind == .photo {
            photos += 1
        } else {
            videos += 1
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
