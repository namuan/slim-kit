import Foundation

@MainActor
enum CompressionDeletionAssessor {
    static func review(
        snapshot: CompressionWorkflowSnapshot,
        userApprovedDeletion: Bool,
        context: CompressionDeletionContext
    ) async -> OriginalDeletionReview {
        var reasons: [String] = []
        if snapshot.phase != .awaitingDeletionDecision && snapshot.phase != .deletingOriginal {
            reasons.append("The workflow is not in an independently verified pre-deletion phase.")
        }
        if !context.importer.canReadAndWritePhotos || !context.deletionService.canDeletePhotos {
            reasons.append("Read-write Photos access is unavailable.")
        }
        let source = await assessSource(snapshot, context: context)
        reasons.append(contentsOf: source.reasons)
        let output = await assessOutput(snapshot)
        let replacementIsVerified = await verifyReplacement(snapshot, context: context)
        if !replacementIsVerified {
            reasons.append("The replacement could not be independently re-verified immediately before deletion.")
        }
        let preconditions = DeletionPreconditions(
            sourceIsEligible: source.isEligible,
            sourceIsUnchanged: source.isUnchanged,
            sourceBytesAreVerified: source.bytesAreVerified,
            outputBytesAreVerified: output.bytesAreVerified,
            outputIsSmallerByMinimum: output.isSmallerByMinimum,
            outputWasValidated: output.wasValidated,
            replacementWasImported: snapshot.replacementAssetID != nil,
            replacementWasIndependentlyVerified: replacementIsVerified,
            sourceIdentifierMatchesJob: sourceIdentifierMatches(snapshot),
            replacementIdentifierIsKnown: snapshot.replacementAssetID != nil,
            userApprovedDeletion: userApprovedDeletion
        )
        return OriginalDeletionReview(
            operationID: snapshot.operationID,
            sourceAssetID: snapshot.verifiedSource.assetID,
            replacementAssetID: snapshot.replacementAssetID,
            potentialBytesToReclaim: source.byteCount,
            preconditions: preconditions,
            additionalBlockingReasons: reasons
        )
    }

    static func emptyReview(operationID: String, reason: String) -> OriginalDeletionReview {
        OriginalDeletionReview(
            operationID: operationID,
            sourceAssetID: "",
            replacementAssetID: nil,
            potentialBytesToReclaim: nil,
            preconditions: DeletionPreconditions(
                sourceIsEligible: false,
                sourceIsUnchanged: false,
                sourceBytesAreVerified: false,
                outputBytesAreVerified: false,
                outputIsSmallerByMinimum: false,
                outputWasValidated: false,
                replacementWasImported: false,
                replacementWasIndependentlyVerified: false,
                sourceIdentifierMatchesJob: false,
                replacementIdentifierIsKnown: false,
                userApprovedDeletion: false
            ),
            additionalBlockingReasons: [reason]
        )
    }

    private static func assessSource(
        _ snapshot: CompressionWorkflowSnapshot,
        context: CompressionDeletionContext
    ) async -> DeletionSourceAssessment {
        do {
            let measurement = try await PhotoResourceExporter.measure(
                assetIdentifier: snapshot.verifiedSource.assetID,
                networkAccessAllowed: context.networkAccessAllowed,
                source: context.resourceSource
            )
            let isEligible = measurement.capabilities == .supported
            let isUnchanged =
                measurement.size.sourceModificationDate == snapshot.verifiedSource.sourceModificationDate &&
                    measurement.size.resourceSelectionBasis == snapshot.verifiedSource.resourceSelectionBasis
            let bytesAreVerified = measurement.size.byteCount == snapshot.verifiedSource.byteCount
            var reasons: [String] = []
            if !isEligible { reasons.append("The current source is not eligible for deletion.") }
            if !isUnchanged { reasons.append("The source state differs from the compression checkpoint.") }
            if !bytesAreVerified { reasons.append("The current source byte count differs from its verified size.") }
            return DeletionSourceAssessment(
                isEligible: isEligible,
                isUnchanged: isUnchanged,
                bytesAreVerified: bytesAreVerified,
                byteCount: measurement.size.byteCount,
                reasons: reasons
            )
        } catch {
            return DeletionSourceAssessment(
                isEligible: false,
                isUnchanged: false,
                bytesAreVerified: false,
                byteCount: nil,
                reasons: ["The current source could not be independently re-verified: \(error.localizedDescription)"]
            )
        }
    }

    private static func assessOutput(_ snapshot: CompressionWorkflowSnapshot) async -> DeletionOutputAssessment {
        let artifact = snapshot.artifact
        let attributes = try? FileManager.default.attributesOfItem(atPath: artifact.outputURL.path)
        let actualBytes = (attributes?[.size] as? NSNumber)?.int64Value
        let bytesAreVerified = actualBytes == artifact.outputBytes && artifact.outputBytes > 0
        let savings = SavingsAssessment(
            source: .verified(snapshot.verifiedSource.byteCount),
            outputBytes: artifact.outputBytes,
            minimumReduction: artifact.preset.policy.minimumSavingsFraction
        )
        let isSmaller: Bool
        if case .qualifies = savings.outcome {
            isSmaller = true
        } else {
            isSmaller = false
        }
        let capabilities: MediaCapabilityDecision
        switch snapshot.mediaKind {
        case .photo:
            capabilities = MediaCapabilityInspector.inspectImage(at: artifact.outputURL)
        case .video:
            capabilities = await MediaCapabilityInspector.inspectVideo(at: artifact.outputURL)
        }
        return DeletionOutputAssessment(
            bytesAreVerified: bytesAreVerified,
            isSmallerByMinimum: isSmaller,
            wasValidated: bytesAreVerified && capabilities == .supported
        )
    }

    private static func verifyReplacement(
        _ snapshot: CompressionWorkflowSnapshot,
        context: CompressionDeletionContext
    ) async -> Bool {
        let importContext = CompressionImportContext(
            networkAccessAllowed: context.networkAccessAllowed,
            resourceSource: context.resourceSource,
            importer: context.importer,
            checkpointStore: context.checkpointStore
        )
        let state = await CompressionImportCoordinator.reverifyReplacement(
            snapshot: snapshot,
            context: importContext,
            successPhase: snapshot.phase
        )
        if case .verified = state { return true }
        return false
    }

    private static func sourceIdentifierMatches(_ snapshot: CompressionWorkflowSnapshot) -> Bool {
        let assetID = snapshot.verifiedSource.assetID
        return assetID == snapshot.artifact.assetID
    }
}

private struct DeletionSourceAssessment {
    let isEligible: Bool
    let isUnchanged: Bool
    let bytesAreVerified: Bool
    let byteCount: Int64?
    let reasons: [String]
}

private struct DeletionOutputAssessment {
    let bytesAreVerified: Bool
    let isSmallerByMinimum: Bool
    let wasValidated: Bool
}
