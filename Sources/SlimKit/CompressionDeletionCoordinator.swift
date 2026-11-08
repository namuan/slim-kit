import Foundation

struct OriginalDeletionReview: Equatable, Sendable {
    let operationID: String
    let sourceAssetID: String
    let replacementAssetID: String?
    let potentialBytesToReclaim: Int64?
    let preconditions: DeletionPreconditions
    let additionalBlockingReasons: [String]

    var blockingReasons: [String] {
        preconditions.blockingReasons.filter { $0 != "user has not approved deletion" } + additionalBlockingReasons
    }

    var isReadyForConfirmation: Bool {
        blockingReasons.isEmpty
    }
}

enum OriginalDeletionResult: Equatable, Sendable {
    case confirmationRequired(OriginalDeletionReview)
    case blocked(OriginalDeletionReview)
    case deleted
    case needsReview(String)
}

@MainActor
struct CompressionDeletionContext {
    let networkAccessAllowed: Bool
    let resourceSource: any ResourceExportSource
    let importer: any PhotosAssetImporting
    let deletionService: any PhotosAssetDeleting
    let checkpointStore: any CompressionWorkflowCheckpointing
}

@MainActor
enum CompressionDeletionCoordinator {
    static func reviewDeletion(
        operationID: String,
        context: CompressionDeletionContext
    ) async -> OriginalDeletionReview {
        guard let snapshot = try? context.checkpointStore.snapshot(operationID: operationID) ?? nil else {
            return CompressionDeletionAssessor.emptyReview(
                operationID: operationID,
                reason: "The workflow checkpoint is unavailable."
            )
        }
        return await CompressionDeletionAssessor.review(
            snapshot: snapshot,
            userApprovedDeletion: true,
            context: context
        )
    }

    static func deleteOriginal(
        operationID: String,
        userConfirmed: Bool,
        context: CompressionDeletionContext
    ) async -> OriginalDeletionResult {
        guard let snapshot = try? context.checkpointStore.snapshot(operationID: operationID) ?? nil else {
            return .needsReview("The workflow checkpoint is unavailable; original deletion was not attempted.")
        }
        guard snapshot.phase == .awaitingDeletionDecision else {
            return .needsReview("The workflow is not awaiting a new deletion decision; no deletion was attempted.")
        }
        let review = await CompressionDeletionAssessor.review(
            snapshot: snapshot,
            userApprovedDeletion: true,
            context: context
        )
        guard review.isReadyForConfirmation else { return .blocked(review) }
        guard userConfirmed else { return .confirmationRequired(review) }
        return await performDeletion(snapshot, context: context)
    }

    static func recoverInterruptedDeletion(
        operationID: String,
        context: CompressionDeletionContext
    ) async -> OriginalDeletionResult {
        guard let snapshot = try? context.checkpointStore.snapshot(operationID: operationID) ?? nil,
              snapshot.phase == .deletingOriginal,
              snapshot.deletionApprovalRecorded else {
            return .needsReview("No recoverable interrupted deletion checkpoint was found.")
        }
        let verificationContext = CompressionImportContext(
            networkAccessAllowed: context.networkAccessAllowed,
            resourceSource: context.resourceSource,
            importer: context.importer,
            checkpointStore: context.checkpointStore
        )
        let verification = await CompressionImportCoordinator.reverifyReplacement(
            snapshot: snapshot,
            context: verificationContext,
            successPhase: .deletingOriginal
        )
        guard case .verified = verification else {
            let message = "Replacement verification or Photos access is uncertain after an interrupted deletion."
            try? context.checkpointStore.save(snapshot.updating(phase: .needsReview, errorMessage: message))
            return .needsReview(message)
        }
        return await reconcileOriginal(snapshot, context: context)
    }

    private static func performDeletion(
        _ snapshot: CompressionWorkflowSnapshot,
        context: CompressionDeletionContext
    ) async -> OriginalDeletionResult {
        let pending = snapshot.updating(
            phase: .deletingOriginal,
            deletionRequested: true,
            deletionApprovalRecorded: true
        )
        do {
            try context.checkpointStore.save(pending)
        } catch {
            return .needsReview("Deletion was not attempted because the approval checkpoint could not be saved.")
        }
        let finalReview = await CompressionDeletionAssessor.review(
            snapshot: pending,
            userApprovedDeletion: true,
            context: context
        )
        guard finalReview.isReadyForConfirmation else {
            let updated = pending.updating(
                phase: .needsReview,
                errorMessage: finalReview.blockingReasons.joined(separator: "; ")
            )
            try? context.checkpointStore.save(updated)
            return .blocked(finalReview)
        }
        return await issueDeletion(pending, context: context)
    }

    private static func issueDeletion(
        _ snapshot: CompressionWorkflowSnapshot,
        context: CompressionDeletionContext
    ) async -> OriginalDeletionResult {
        do {
            try await context.deletionService.deleteAsset(assetID: snapshot.verifiedSource.assetID)
            guard try await context.importer.snapshot(assetID: snapshot.verifiedSource.assetID) == nil else {
                return await markNeedsReview(
                    snapshot,
                    message: "Photos reported deletion success but the original is still present. " +
                        "Do not retry automatically.",
                    context: context
                )
            }
            let completed = snapshot.updating(
                phase: .completed,
                deletionRequested: true,
                deletionApprovalRecorded: true,
                deletionTransactionSucceeded: true
            )
            try context.checkpointStore.save(completed)
            return .deleted
        } catch {
            return await markNeedsReview(
                snapshot,
                message: "The Photos deletion outcome is uncertain: \(error.localizedDescription)",
                context: context
            )
        }
    }

    private static func reconcileOriginal(
        _ snapshot: CompressionWorkflowSnapshot,
        context: CompressionDeletionContext
    ) async -> OriginalDeletionResult {
        do {
            if try await context.importer.snapshot(assetID: snapshot.verifiedSource.assetID) == nil {
                let completed = snapshot.updating(phase: .completed, deletionTransactionSucceeded: true)
                try context.checkpointStore.save(completed)
                return .deleted
            }
            return await markNeedsReview(
                snapshot,
                message: "The original is still present after an interrupted deletion. " +
                    "No second deletion was attempted.",
                context: context
            )
        } catch {
            return await markNeedsReview(
                snapshot,
                message: "The original's state could not be reconciled: \(error.localizedDescription)",
                context: context
            )
        }
    }

    private static func markNeedsReview(
        _ snapshot: CompressionWorkflowSnapshot,
        message: String,
        context: CompressionDeletionContext
    ) async -> OriginalDeletionResult {
        try? context.checkpointStore.save(snapshot.updating(phase: .needsReview, errorMessage: message))
        return .needsReview(message)
    }
}
