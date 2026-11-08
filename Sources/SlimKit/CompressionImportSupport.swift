import Foundation

@MainActor
struct CompressionImportContext {
    let networkAccessAllowed: Bool
    let resourceSource: any ResourceExportSource
    let importer: any PhotosAssetImporting
    let checkpointStore: any CompressionWorkflowCheckpointing
}

enum CompressionImportValidation {
    static func validate(
        request: CompressionImportRequest,
        resourceSource: any ResourceExportSource
    ) async throws {
        let artifact = request.artifact
        let verifiedSource = artifact.verifiedSource
        guard artifact.hasCurrentSourceCheckpoint,
              artifact.assetID == verifiedSource.assetID,
              artifact.sourceBytes == verifiedSource.byteCount,
              artifact.outputBytes > 0,
              artifact.sourceBytes > artifact.outputBytes,
              artifact.savedBytes == artifact.sourceBytes - artifact.outputBytes,
              !verifiedSource.resourceSelectionBasis.isEmpty else {
            throw CompressionEngineError.outputValidationFailed
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: artifact.outputURL.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == artifact.outputBytes else {
            throw ResourceExportError.byteCountMismatch
        }
        let savings = SavingsAssessment(
            source: .verified(artifact.sourceBytes),
            outputBytes: artifact.outputBytes,
            minimumReduction: artifact.preset.policy.minimumSavingsFraction
        )
        guard case .qualifies = savings.outcome else {
            throw CompressionEngineError.outputValidationFailed
        }
        guard await outputIsSupported(artifact, kind: request.mediaKind) else {
            throw CompressionEngineError.outputValidationFailed
        }
        try verifyCurrentSource(verifiedSource, kind: request.mediaKind, source: resourceSource)
    }

    static func metadataMismatch(
        snapshot: CompressionWorkflowSnapshot,
        replacement: PhotosAssetSnapshot
    ) -> String? {
        let artifact = snapshot.artifact
        guard replacement.assetID == snapshot.replacementAssetID,
              replacement.mediaKind == snapshot.mediaKind else {
            return "The imported replacement has the wrong identifier or media type."
        }
        guard replacement.pixelWidth == artifact.pixelWidth,
              replacement.pixelHeight == artifact.pixelHeight else {
            return "The imported replacement dimensions do not match the validated output."
        }
        if let mismatch = videoDurationMismatch(snapshot: snapshot, replacement: replacement) {
            return mismatch
        }
        if let creationDate = snapshot.importMetadata.creationDate,
           replacement.creationDate.map({ abs($0.timeIntervalSince(creationDate)) <= 1 }) != true {
            return "The imported replacement did not preserve the selected creation date."
        }
        if let location = snapshot.importMetadata.location,
           replacement.location.map({ location.matches($0) }) != true {
            return "The imported replacement did not preserve the selected location."
        }
        return nil
    }

    private static func verifyCurrentSource(
        _ verifiedSource: VerifiedResourceSize,
        kind: MediaAsset.Kind,
        source: any ResourceExportSource
    ) throws {
        guard source.canReadPhotos else { throw ResourceExportError.accessUnavailable }
        let selected = try source.selectResource(assetIdentifier: verifiedSource.assetID)
        guard selected.kind == kind,
              selected.sourceModificationDate == verifiedSource.sourceModificationDate,
              selected.basis == verifiedSource.resourceSelectionBasis else {
            throw ResourceExportError.sourceChanged
        }
        try selected.verifySource()
    }

    private static func outputIsSupported(_ artifact: CompressedMediaArtifact, kind: MediaAsset.Kind) async -> Bool {
        let decision: MediaCapabilityDecision
        switch kind {
        case .photo:
            decision = MediaCapabilityInspector.inspectImage(at: artifact.outputURL)
        case .video:
            decision = await MediaCapabilityInspector.inspectVideo(at: artifact.outputURL)
        }
        return decision == .supported
    }

    private static func videoDurationMismatch(
        snapshot: CompressionWorkflowSnapshot,
        replacement: PhotosAssetSnapshot
    ) -> String? {
        guard snapshot.mediaKind == .video else { return nil }
        guard let expectedDuration = snapshot.artifact.videoDuration,
              let frameRate = snapshot.artifact.videoFrameRate,
              frameRate.isFinite,
              frameRate > 0,
              let actualDuration = replacement.duration,
              actualDuration.isFinite,
              abs(actualDuration - expectedDuration) <= 1 / frameRate else {
            return "The imported video duration differs from the validated output by more than one frame."
        }
        return nil
    }
}

@MainActor
enum CompressionReplacementVerifier {
    static func resume(
        snapshot: CompressionWorkflowSnapshot,
        context: CompressionImportContext
    ) async -> CompressionImportResult {
        if snapshot.phase == .awaitingDeletionDecision || snapshot.phase == .completed {
            return result(snapshot: snapshot, state: .verified)
        }
        guard snapshot.replacementAssetID != nil else {
            let reason = "An earlier import has no saved replacement identifier. No duplicate import was attempted."
            let updated = snapshot.updating(phase: .needsReview, errorMessage: reason)
            try? context.checkpointStore.save(updated)
            return result(snapshot: snapshot, state: .needsReview(reason))
        }
        let state = await verify(snapshot: snapshot, context: context)
        return result(snapshot: snapshot, state: state)
    }

    static func verify(
        snapshot: CompressionWorkflowSnapshot,
        context: CompressionImportContext,
        successPhase: CompressionPhase = .awaitingDeletionDecision
    ) async -> ImportVerificationState {
        let state = await assess(snapshot: snapshot, context: context)
        return persist(snapshot: snapshot, state: state, successPhase: successPhase, context: context)
    }

    private static func assess(
        snapshot: CompressionWorkflowSnapshot,
        context: CompressionImportContext
    ) async -> ImportVerificationState {
        guard let replacementID = snapshot.replacementAssetID else {
            return .needsReview("The replacement identifier is missing.")
        }
        do {
            guard let replacement = try await context.importer.snapshot(assetID: replacementID) else {
                return .pending("Photos has not made the replacement available for verification yet.")
            }
            if let mismatch = CompressionImportValidation.metadataMismatch(
                snapshot: snapshot,
                replacement: replacement
            ) {
                return .failed(mismatch)
            }
            let measurement = try await PhotoResourceExporter.measure(
                assetIdentifier: replacementID,
                networkAccessAllowed: context.networkAccessAllowed,
                source: context.resourceSource
            )
            guard measurement.capabilities == .supported else {
                return .failed(
                    "The imported resource failed capability inspection: \(measurement.capabilities.logLabel)"
                )
            }
            guard measurement.size.byteCount == snapshot.artifact.outputBytes else {
                return .failed("The imported resource byte count does not match the validated compressed output.")
            }
            return .verified
        } catch let error as ResourceExportError {
            if case .unsupported = error { return .failed(error.localizedDescription) }
            return .pending(error.localizedDescription)
        } catch {
            return .pending(error.localizedDescription)
        }
    }

    private static func persist(
        snapshot: CompressionWorkflowSnapshot,
        state: ImportVerificationState,
        successPhase: CompressionPhase,
        context: CompressionImportContext
    ) -> ImportVerificationState {
        let phase: CompressionPhase
        switch state {
        case .verified:
            phase = successPhase
        case .pending:
            phase = .verifyingImport
        case .failed:
            phase = .failed
        case .needsReview:
            phase = .needsReview
        }
        let updated = snapshot.updating(
            phase: phase,
            errorMessage: state.message
        )
        do {
            try context.checkpointStore.save(updated)
            return state
        } catch {
            return .needsReview("Verification state could not be saved: \(error.localizedDescription)")
        }
    }

    private static func result(
        snapshot: CompressionWorkflowSnapshot,
        state: ImportVerificationState
    ) -> CompressionImportResult {
        CompressionImportResult(
            operationID: snapshot.operationID,
            replacementAssetID: snapshot.replacementAssetID,
            state: state
        )
    }
}

private extension ImportVerificationState {
    var message: String? {
        switch self {
        case .verified:
            nil
        case let .pending(message), let .failed(message), let .needsReview(message):
            message
        }
    }
}
