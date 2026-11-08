import Foundation
import SwiftData
import SwiftUI

extension ContentView {
    var compressionProgressLabel: String {
        guard let compressionProgress else { return "Preparing compression…" }
        return "\(compressionProgress.phase.rawValue) · " +
            "\(compressionProgress.completedJobCount) of \(compressionProgress.totalJobCount)"
    }

    var deletionConfirmationMessage: String {
        let bytes = pendingDeletionReview?.potentialBytesToReclaim ?? nil
        let estimate = bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "unknown"
        return "SlimKit freshly verified the replacement and measured the original resource at \(estimate). " +
            "This is not a promise of reclaimed storage. Photos may retain the original in Recently Deleted; " +
            "iCloud synchronization can propagate removal to your devices. " +
            "Edits and Photos relationships are not copied."
    }

    func retryReplacementVerification(_ snapshot: CompressionWorkflowSnapshot) {
        let importer = PhotoKitAssetImporter()
        let store = SwiftDataCompressionWorkflowStore(modelContext: modelContext)
        Task { @MainActor in
            let context = CompressionImportContext(
                networkAccessAllowed: false,
                resourceSource: PhotoKitResourceSource(),
                importer: importer,
                checkpointStore: store
            )
            let state = await CompressionImportCoordinator.reverifyReplacement(
                snapshot: snapshot,
                context: context
            )
            switch state {
            case .verified:
                importStatusMessages.append(
                    "\(snapshot.operationID): replacement independently verified; original retained."
                )
            case let .pending(message):
                importStatusMessages.append(
                    "\(snapshot.operationID): verification remains pending; \(message)"
                )
            case let .failed(message):
                importStatusMessages.append(
                    "\(snapshot.operationID): verification failed; original retained. \(message)"
                )
            case let .needsReview(message):
                importStatusMessages.append(
                    "\(snapshot.operationID): needs review. \(message)"
                )
            }
        }
    }

    func prepareOriginalDeletion(networkAccessAllowed: Bool) {
        guard let operationID = pendingDeletionOperationID else { return }
        let importer = PhotoKitAssetImporter()
        let store = SwiftDataCompressionWorkflowStore(modelContext: modelContext)
        let context = deletionContext(
            networkAccessAllowed: networkAccessAllowed,
            importer: importer,
            store: store
        )
        Task { @MainActor in
            let review = await CompressionDeletionCoordinator.reviewDeletion(
                operationID: operationID,
                context: context
            )
            pendingDeletionReview = review
            deletionNetworkAccessAllowed = networkAccessAllowed
            if review.isReadyForConfirmation {
                showingDeletionConfirmation = true
            } else {
                deletionStatusMessage = "Deletion blocked: \(review.blockingReasons.joined(separator: "; "))"
            }
        }
    }

    func deleteOriginalAfterConfirmation() {
        guard let operationID = pendingDeletionOperationID else { return }
        let importer = PhotoKitAssetImporter()
        let store = SwiftDataCompressionWorkflowStore(modelContext: modelContext)
        let context = deletionContext(
            networkAccessAllowed: deletionNetworkAccessAllowed,
            importer: importer,
            store: store
        )
        Task { @MainActor in
            let result = await CompressionDeletionCoordinator.deleteOriginal(
                operationID: operationID,
                userConfirmed: true,
                context: context
            )
            switch result {
            case .deleted:
                deletionStatusMessage = "Photos confirmed the original was removed from the library. " +
                    "Reclaimed storage was not measured."
                library.refreshAssets()
            case let .blocked(review):
                deletionStatusMessage = "Deletion blocked: \(review.blockingReasons.joined(separator: "; "))"
            case .confirmationRequired:
                deletionStatusMessage = "A separate explicit confirmation is required."
            case let .needsReview(message):
                deletionStatusMessage = "Needs review; no automatic retry was attempted. \(message)"
            }
            pendingDeletionReview = nil
            pendingDeletionOperationID = nil
        }
    }

    func recoverInterruptedDeletion(_ operationID: String) {
        let importer = PhotoKitAssetImporter()
        let store = SwiftDataCompressionWorkflowStore(modelContext: modelContext)
        let context = deletionContext(networkAccessAllowed: false, importer: importer, store: store)
        Task { @MainActor in
            let result = await CompressionDeletionCoordinator.recoverInterruptedDeletion(
                operationID: operationID,
                context: context
            )
            switch result {
            case .deleted:
                deletionStatusMessage = "Recovery confirmed the original is absent. Reclaimed storage was not measured."
                library.refreshAssets()
            case let .needsReview(message):
                deletionStatusMessage = "Needs review; no new deletion was attempted. \(message)"
            case let .blocked(review):
                deletionStatusMessage = "Needs review: \(review.blockingReasons.joined(separator: "; "))"
            case .confirmationRequired:
                deletionStatusMessage = "Recovery never requests a new deletion confirmation."
            }
        }
    }

    func restoreRetainedArtifacts() {
        reconcileIncompleteImports()
        guard compressionResults.isEmpty,
              let workspaceManager = try? CompressionWorkspaceManager.applicationSupport() else { return }
        let checkpointIDs = Set(workflowRecords.map(\.operationID))
        compressionResults = workspaceManager.loadRetainedArtifacts()
            .filter { !checkpointIDs.contains($0.operationID) }
            .map { CompressionQueueResult(assetID: $0.assetID, result: .compressed($0)) }
    }

    private func reconcileIncompleteImports() {
        let store = SwiftDataCompressionWorkflowStore(modelContext: modelContext)
        for record in workflowRecords {
            guard let snapshot = try? record.snapshot(),
                  snapshot.phase == .importing,
                  snapshot.replacementAssetID == nil else { continue }
            let reason = "An earlier import has no saved replacement identifier. No duplicate import was attempted."
            try? store.save(snapshot.updating(phase: .needsReview, errorMessage: reason))
        }
    }

    func startCompression(networkAccessAllowed: Bool) {
        guard let jobs = makeCompressionJobs(networkAccessAllowed: networkAccessAllowed) else { return }
        guard let workspaceManager = try? CompressionWorkspaceManager.applicationSupport() else {
            compressionStatusMessage = "The local compression workspace could not be prepared."
            return
        }
        compressionResults = []
        importStatusMessages = []
        compressionStatusMessage = nil
        isCompressing = true
        compressionTask = Task { @MainActor in
            let results = await CompressionJobQueue.run(
                jobs: jobs,
                workspaceManager: workspaceManager,
                progress: { progress in
                    Task { @MainActor in compressionProgress = progress }
                }
            )
            compressionResults = results
            compressionProgress = nil
            compressionTask = nil
            isCompressing = false
            let summary = CompressionBatchSummary(results: results)
            compressionStatusMessage = summaryMessage(summary)
        }
    }

    func importCompressedResults(networkAccessAllowed: Bool) {
        let artifacts = compressionResults.compactMap { result -> CompressedMediaArtifact? in
            if case let .compressed(artifact) = result.result { return artifact }
            return nil
        }
        guard !artifacts.isEmpty else { return }
        let importer = PhotoKitAssetImporter()
        guard importer.canReadAndWritePhotos else {
            importStatusMessages = [PhotosImportError.accessUnavailable.localizedDescription]
            return
        }
        let store = SwiftDataCompressionWorkflowStore(modelContext: modelContext)
        isImporting = true
        importStatusMessages = []
        Task { @MainActor in
            var messages: [String] = []
            for artifact in artifacts {
                do {
                    guard let source = try await importer.snapshot(assetID: artifact.assetID) else {
                        messages.append(
                    "\(artifact.assetID): source is unavailable; import was not attempted."
                )
                        continue
                    }
                    let request = CompressionImportRequest(
                        artifact: artifact,
                        mediaKind: source.mediaKind,
                        metadata: CompressionImportMetadata(
                            creationDate: source.creationDate,
                            location: source.location
                        ),
                        networkAccessAllowed: networkAccessAllowed
                    )
                    let result = await CompressionImportCoordinator.importAndVerify(
                        request: request,
                        resourceSource: PhotoKitResourceSource(),
                        importer: importer,
                        checkpointStore: store
                    )
                    messages.append(importResultMessage(result))
                } catch {
                    messages.append(
                        "\(artifact.assetID): import was not attempted: \(error.localizedDescription)"
                    )
                }
            }
            importStatusMessages = messages
            isImporting = false
            restoreRetainedArtifacts()
        }
    }

    func importResultMessage(_ result: CompressionImportResult) -> String {
        switch result.state {
        case .verified:
            "\(result.operationID): replacement \(result.replacementAssetID ?? "unknown") " +
                "independently verified; original retained."
        case let .pending(message):
            "\(result.operationID): verification pending; original retained. \(message)"
        case let .failed(message):
            "\(result.operationID): import or verification failed; " +
                "original retained. \(message)"
        case let .needsReview(message):
            "\(result.operationID): needs review; no retry or deletion was attempted. " +
                message
        }
    }

    private func deletionContext(
        networkAccessAllowed: Bool,
        importer: PhotoKitAssetImporter,
        store: SwiftDataCompressionWorkflowStore
    ) -> CompressionDeletionContext {
        CompressionDeletionContext(
            networkAccessAllowed: networkAccessAllowed,
            resourceSource: PhotoKitResourceSource(),
            importer: importer,
            deletionService: importer,
            checkpointStore: store
        )
    }

    private func makeCompressionJobs(networkAccessAllowed: Bool) -> [CompressionQueueJob]? {
        let assets = library.assets.filter { selectedIDs.contains($0.id) }
        guard !assets.isEmpty else { return nil }
        var jobs: [CompressionQueueJob] = []
        for asset in assets {
            guard let record = sizeRecordsByID[asset.id], record.isValid(for: asset) else {
                compressionStatusMessage = "Verify current sizes before compressing selected items."
                return nil
            }
            guard record.capabilityDecision(for: asset) == .supported else {
                compressionStatusMessage = "Selected items must pass current capability inspection before compression."
                return nil
            }
            jobs.append(makeCompressionJob(asset: asset, record: record, networkAccessAllowed: networkAccessAllowed))
        }
        return jobs
    }

    private func makeCompressionJob(
        asset: MediaAsset,
        record: VerifiedSizeRecord,
        networkAccessAllowed: Bool
    ) -> CompressionQueueJob {
        let verifiedSize = VerifiedResourceSize(
            assetID: record.assetID,
            byteCount: record.byteCount,
            sourceModificationDate: record.sourceModificationDate,
            resourceSelectionBasis: record.resourceSelectionBasis,
            measuredAt: record.measuredAt
        )
        return CompressionQueueJob(
            verifiedSize: verifiedSize,
            mediaKind: asset.kind,
            preset: compressionPreset,
            networkAccessAllowed: networkAccessAllowed
        )
    }

    private func summaryMessage(_ summary: CompressionBatchSummary) -> String {
        "Compression finished: \(summary.completedCount) ready, \(summary.failedCount) failed, " +
            "\(summary.skippedCount) skipped, \(summary.unchangedCount) unchanged, " +
            "\(summary.sizeUnverifiedCount) size unverified. Photos was not changed."
    }
}
