import Foundation

struct CompressionImportRequest: Sendable {
    let operationID: String
    let artifact: CompressedMediaArtifact
    let mediaKind: MediaAsset.Kind
    let metadata: CompressionImportMetadata
    let networkAccessAllowed: Bool

    init(
        operationID: String? = nil,
        artifact: CompressedMediaArtifact,
        mediaKind: MediaAsset.Kind,
        metadata: CompressionImportMetadata,
        networkAccessAllowed: Bool
    ) {
        self.operationID = operationID ?? artifact.operationID
        self.artifact = artifact
        self.mediaKind = mediaKind
        self.metadata = metadata
        self.networkAccessAllowed = networkAccessAllowed
    }
}

@MainActor
enum CompressionImportCoordinator {
    static func importAndVerify(
        request: CompressionImportRequest,
        resourceSource: any ResourceExportSource,
        importer: any PhotosAssetImporting,
        checkpointStore: any CompressionWorkflowCheckpointing
    ) async -> CompressionImportResult {
        let context = CompressionImportContext(
            networkAccessAllowed: request.networkAccessAllowed,
            resourceSource: resourceSource,
            importer: importer,
            checkpointStore: checkpointStore
        )
        do {
            if let existing = try checkpointStore.snapshot(operationID: request.operationID) {
                return await CompressionReplacementVerifier.resume(snapshot: existing, context: context)
            }
        } catch {
            let message = "The workflow checkpoint could not be read; no import was attempted."
            return result(request, state: .needsReview(message))
        }
        return await importNewArtifact(request, context: context)
    }

    static func reverifyReplacement(
        snapshot: CompressionWorkflowSnapshot,
        context: CompressionImportContext,
        successPhase: CompressionPhase = .awaitingDeletionDecision
    ) async -> ImportVerificationState {
        await CompressionReplacementVerifier.verify(
            snapshot: snapshot,
            context: context,
            successPhase: successPhase
        )
    }

    private static func importNewArtifact(
        _ request: CompressionImportRequest,
        context: CompressionImportContext
    ) async -> CompressionImportResult {
        do {
            try await CompressionImportValidation.validate(
                request: request,
                resourceSource: context.resourceSource
            )
        } catch {
            return result(request, state: .failed(error.localizedDescription))
        }
        guard context.importer.canReadAndWritePhotos else {
            return result(request, state: .failed(PhotosImportError.accessUnavailable.localizedDescription))
        }
        let snapshot = CompressionWorkflowSnapshot(
            operationID: request.operationID,
            mediaKind: request.mediaKind,
            verifiedSource: request.artifact.verifiedSource,
            artifact: request.artifact,
            importMetadata: request.metadata,
            phase: .importing
        )
        do {
            try context.checkpointStore.save(snapshot)
        } catch {
            let message = "Import was not started because its recovery checkpoint could not be saved."
            return result(request, state: .failed(message))
        }
        return await beginImport(snapshot, request: request, context: context)
    }

    private static func beginImport(
        _ snapshot: CompressionWorkflowSnapshot,
        request: CompressionImportRequest,
        context: CompressionImportContext
    ) async -> CompressionImportResult {
        do {
            let identifier = try await context.importer.importAsset(
                from: request.artifact.outputURL,
                mediaKind: request.mediaKind,
                metadata: request.metadata
            )
            let verifying = snapshot.updating(phase: .verifyingImport, replacementAssetID: identifier)
            do {
                try context.checkpointStore.save(verifying)
            } catch {
                let message = "The replacement was imported but its identifier could not be saved. " +
                    "Do not retry this import."
                return result(request, replacementID: identifier, state: .needsReview(message))
            }
            let state = await CompressionReplacementVerifier.verify(snapshot: verifying, context: context)
            return result(request, replacementID: identifier, state: state)
        } catch PhotosImportError.placeholderIdentifierUnavailable {
            let reason = PhotosImportError.placeholderIdentifierUnavailable.localizedDescription
            try? context.checkpointStore.save(snapshot.updating(phase: .needsReview, errorMessage: reason))
            return result(request, state: .needsReview(reason))
        } catch {
            let failed = snapshot.updating(phase: .failed, errorMessage: error.localizedDescription)
            try? context.checkpointStore.save(failed)
            return result(request, state: .failed(error.localizedDescription))
        }
    }

    private static func result(
        _ request: CompressionImportRequest,
        replacementID: String? = nil,
        state: ImportVerificationState
    ) -> CompressionImportResult {
        CompressionImportResult(
            operationID: request.operationID,
            replacementAssetID: replacementID,
            state: state
        )
    }
}
