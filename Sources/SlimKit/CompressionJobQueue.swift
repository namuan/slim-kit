import Foundation

struct CompressionQueueJob: Sendable {
    let verifiedSize: VerifiedResourceSize
    let mediaKind: MediaAsset.Kind
    let preset: CompressionPreset
    let networkAccessAllowed: Bool
}

struct CompressionQueueProgress: Equatable, Sendable {
    let assetID: String
    let completedJobCount: Int
    let totalJobCount: Int
    let phase: CompressionPhase
    let fractionCompleted: Double?
}

typealias CompressionQueueProgressHandler = @Sendable (CompressionQueueProgress) -> Void

enum CompressionJobResult: Equatable, Sendable {
    case compressed(CompressedMediaArtifact)
    case skipped(CompressionSkipReason)
    case failed(String)
    case cancelled
}

struct CompressionQueueResult: Equatable, Sendable {
    let assetID: String
    let result: CompressionJobResult
}

private struct CompressionQueueContext {
    let source: any ResourceExportSource
    let workspaceManager: CompressionWorkspaceManager
    let progress: CompressionProgressHandler
}

enum CompressionJobQueue {
    static func run(
        jobs: [CompressionQueueJob],
        source: any ResourceExportSource = PhotoKitResourceSource(),
        workspaceManager: CompressionWorkspaceManager,
        progress: @escaping CompressionQueueProgressHandler = { _ in }
    ) async -> [CompressionQueueResult] {
        var results: [CompressionQueueResult] = []
        for index in jobs.indices {
            if Task.isCancelled {
                results.append(contentsOf: cancelledResults(for: jobs[index...]))
                break
            }
            let context = CompressionQueueContext(
                source: source,
                workspaceManager: workspaceManager,
                progress: makeProgressHandler(
                    assetID: jobs[index].verifiedSize.assetID,
                    index: index,
                    total: jobs.count,
                    report: progress
                )
            )
            let result = await process(jobs[index], context: context)
            results.append(result)
            if result.result == .cancelled {
                results.append(contentsOf: cancelledResults(for: jobs.dropFirst(index + 1)))
                break
            }
        }
        return results
    }

    private static func process(
        _ job: CompressionQueueJob,
        context: CompressionQueueContext
    ) async -> CompressionQueueResult {
        let progressHandler = context.progress
        var workspace: CompressionWorkspace?
        do {
            let currentWorkspace = try context.workspaceManager.create(sourceByteCount: job.verifiedSize.byteCount)
            workspace = currentWorkspace
            let attempt = try await compress(
                job,
                source: context.source,
                workspace: currentWorkspace,
                progress: progressHandler
            )
            try Task.checkCancellation()
            switch attempt {
            case let .compressed(artifact):
                let retainedArtifact = try context.workspaceManager.retainArtifact(artifact, from: currentWorkspace)
                workspace = nil
                progressHandler(.completed, 1)
                return CompressionQueueResult(
                    assetID: job.verifiedSize.assetID,
                    result: .compressed(retainedArtifact)
                )
            case let .skipped(reason):
                try? currentWorkspace.cleanup()
                workspace = nil
                progressHandler(.skipped, nil)
                return CompressionQueueResult(assetID: job.verifiedSize.assetID, result: .skipped(reason))
            }
        } catch is CancellationError {
            try? workspace?.cleanup()
            progressHandler(.cancelled, nil)
            return CompressionQueueResult(assetID: job.verifiedSize.assetID, result: .cancelled)
        } catch {
            try? workspace?.cleanup()
            progressHandler(.failed, nil)
            return CompressionQueueResult(
                assetID: job.verifiedSize.assetID,
                result: .failed(error.localizedDescription)
            )
        }
    }

    private static func compress(
        _ job: CompressionQueueJob,
        source: any ResourceExportSource,
        workspace: CompressionWorkspace,
        progress: @escaping CompressionProgressHandler
    ) async throws -> CompressionAttempt {
        progress(.downloading, 0)
        let input = try await PhotoResourceExporter.exportForCompression(
            verifiedSize: job.verifiedSize,
            workspace: workspace,
            networkAccessAllowed: job.networkAccessAllowed,
            source: source,
            progressHandler: { fraction in progress(.downloading, fraction) }
        )
        try Task.checkCancellation()
        switch job.mediaKind {
        case .photo:
            return try ImageCompressionEngine.compress(
                input: input,
                preset: job.preset,
                workspace: workspace,
                progress: progress
            )
        case .video:
            return try await VideoCompressionEngine.compress(
                input: input,
                preset: job.preset,
                workspace: workspace,
                progress: progress
            )
        }
    }

    private static func makeProgressHandler(
        assetID: String,
        index: Int,
        total: Int,
        report: @escaping CompressionQueueProgressHandler
    ) -> CompressionProgressHandler {
        { phase, fraction in
            report(
                CompressionQueueProgress(
                    assetID: assetID,
                    completedJobCount: isTerminal(phase) ? index + 1 : index,
                    totalJobCount: total,
                    phase: phase,
                    fractionCompleted: fraction
                )
            )
        }
    }

    private static func isTerminal(_ phase: CompressionPhase) -> Bool {
        [.completed, .skipped, .failed, .cancelled].contains(phase)
    }

    private static func cancelledResults<S: Collection>(for jobs: S) -> [CompressionQueueResult]
    where S.Element == CompressionQueueJob {
        jobs.map { CompressionQueueResult(assetID: $0.verifiedSize.assetID, result: .cancelled) }
    }
}
