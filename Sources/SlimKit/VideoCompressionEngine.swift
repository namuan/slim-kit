import AVFoundation
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

struct VideoCompressionEngine {
    static func compress(
        input: LocalCompressionInput,
        preset: CompressionPreset,
        workspace: CompressionWorkspace,
        progress: CompressionProgressHandler? = nil
    ) async throws -> CompressionAttempt {
        let preparation = try await VideoCompressionPreparer.prepare(
            input: input,
            preset: preset,
            workspace: workspace
        )
        switch preparation {
        case let .skipped(reason):
            return .skipped(reason)
        case let .ready(job):
            return try await execute(job, input: input, preset: preset, progress: progress)
        }
    }

    private static func execute(
        _ job: VideoCompressionJob,
        input: LocalCompressionInput,
        preset: CompressionPreset,
        progress: CompressionProgressHandler?
    ) async throws -> CompressionAttempt {
        var keepOutput = false
        defer {
            if !keepOutput { try? FileManager.default.removeItem(at: job.outputURL) }
        }
        try Task.checkCancellation()
        try await export(job.session, progress: progress)
        progress?(.validating, nil)
        let output = try await validatedOutput(
            input: input,
            sourceIdentity: job.sourceIdentity,
            sourceProperties: job.sourceProperties,
            outputURL: job.outputURL,
            preset: preset
        )
        try Task.checkCancellation()
        let savings = SavingsAssessment(
            source: .verified(input.verifiedSize.byteCount),
            outputBytes: output.identity.byteCount,
            minimumReduction: preset.policy.minimumSavingsFraction
        )
        guard case let .qualifies(savedBytes, savingsFraction) = savings.outcome else {
            return .skipped(VideoCompressionPreparer.skipReason(for: savings.outcome))
        }
        let artifact = CompressedMediaArtifact(
            assetID: input.verifiedSize.assetID,
            preset: preset,
            sourceBytes: input.verifiedSize.byteCount,
            outputBytes: output.identity.byteCount,
            savedBytes: savedBytes,
            savingsFraction: savingsFraction,
            outputTypeIdentifier: UTType.mpeg4Movie.identifier,
            pixelWidth: output.properties.width,
            pixelHeight: output.properties.height,
            outputURL: job.outputURL
        )
        keepOutput = true
        return .compressed(artifact)
    }

    private static func validatedOutput(
        input: LocalCompressionInput,
        sourceIdentity: VideoFileIdentity,
        sourceProperties: VideoFileProperties,
        outputURL: URL,
        preset: CompressionPreset
    ) async throws -> ValidatedVideoOutput {
        try Task.checkCancellation()
        try input.verifySourceIsCurrent()
        guard sourceIdentity == (try fileIdentity(at: input.sourceURL)) else {
            throw CompressionEngineError.sourceChanged
        }
        guard let identity = try? fileIdentity(at: outputURL) else {
            throw CompressionEngineError.outputSizeUnavailable
        }
        let properties = try await videoProperties(at: outputURL)
        let capabilities = await MediaCapabilityInspector.inspectVideo(at: outputURL)
        guard capabilities == .supported else {
            let sourceColor = [
                sourceProperties.colorPrimaries ?? "nil",
                sourceProperties.transferFunction ?? "nil",
                sourceProperties.yCbCrMatrix ?? "nil"
            ].joined(separator: "/")
            let outputColor = [
                properties.colorPrimaries ?? "nil",
                properties.transferFunction ?? "nil",
                properties.yCbCrMatrix ?? "nil"
            ].joined(separator: "/")
            let message = [
                "Exported video capabilities are uncertain: \(capabilities.logLabel)",
                "sourceColor=\(sourceColor)",
                "outputColor=\(outputColor)"
            ].joined(separator: "; ")
            AppLogger.shared.error("VideoCompression", message)
            throw CompressionEngineError.outputValidationFailed
        }
        guard preservesVideoProperties(sourceProperties, output: properties),
              preservesPresetDimensions(preset, output: properties) else {
            logValidationMismatch(source: sourceProperties, output: properties)
            throw CompressionEngineError.outputValidationFailed
        }
        return ValidatedVideoOutput(identity: identity, properties: properties)
    }

    private static func preservesVideoProperties(
        _ source: VideoFileProperties,
        output: VideoFileProperties
    ) -> Bool {
        output.audioTrackCount == source.audioTrackCount &&
            output.otherTrackCount == 0 &&
            output.width <= source.width &&
            output.height <= source.height &&
            abs(output.aspectRatio - source.aspectRatio) <= 0.01 &&
            output.frameRate.isFinite &&
            output.frameRate > 0 &&
            abs(output.duration - source.duration) <= 1 / source.frameRate
    }

    private static func preservesPresetDimensions(
        _ preset: CompressionPreset,
        output: VideoFileProperties
    ) -> Bool {
        guard let maximumVideoDimension = preset.policy.maximumVideoDimension else { return true }
        return max(output.width, output.height) <= maximumVideoDimension
    }

    private static func logValidationMismatch(source: VideoFileProperties, output: VideoFileProperties) {
        let sourceSummary = "\(source.width)x\(source.height), \(source.duration)s, " +
            "\(source.frameRate)fps, audio=\(source.audioTrackCount)"
        let outputSummary = "\(output.width)x\(output.height), \(output.duration)s, " +
            "\(output.frameRate)fps, audio=\(output.audioTrackCount), other=\(output.otherTrackCount)"
        AppLogger.shared.error(
            "VideoCompression",
            "Export validation mismatch; source=\(sourceSummary); output=\(outputSummary)"
        )
    }

    fileprivate static func export(
        _ session: AVAssetExportSession,
        progress: CompressionProgressHandler?
    ) async throws {
        let handle = VideoExportSessionHandle(session: session)
        let progressMonitor = Task {
            while !Task.isCancelled {
                if let progress {
                    progress(.compressing, Double(handle.session.progress))
                }
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    break
                }
            }
        }
        defer { progressMonitor.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                handle.session.exportAsynchronously {
                    switch handle.session.status {
                    case .completed:
                        continuation.resume()
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    default:
                        continuation.resume(
                            throwing: handle.session.error ?? CompressionEngineError.videoEncodingFailed
                        )
                    }
                }
            }
        } onCancel: {
            handle.session.cancelExport()
        }
    }

    fileprivate static func videoComposition(for source: VideoFileProperties) async throws -> AVVideoComposition {
        let prototype = AVMutableVideoCompositionInstruction()
        return try await withCheckedThrowingContinuation { continuation in
            AVMutableVideoComposition.videoComposition(
                withPropertiesOf: source.asset,
                prototypeInstruction: prototype
            ) { composition, error in
                if let composition {
                    composition.colorPrimaries = source.colorPrimaries
                    composition.colorTransferFunction = source.transferFunction
                    composition.colorYCbCrMatrix = source.yCbCrMatrix
                    continuation.resume(returning: composition)
                } else {
                    continuation.resume(throwing: error ?? CompressionEngineError.videoEncodingFailed)
                }
            }
        }
    }

    fileprivate static func videoProperties(at url: URL) async throws -> VideoFileProperties {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.load(.tracks)
        let videoTracks = tracks.filter { $0.mediaType == .video }
        let audioTrackCount = tracks.filter { $0.mediaType == .audio }.count
        let otherTrackCount = tracks.count - videoTracks.count - audioTrackCount
        guard videoTracks.count == 1,
              let videoTrack = videoTracks.first else {
            let message = "Expected one video track at \(url.lastPathComponent); found \(videoTracks.count)"
            AppLogger.shared.error("VideoCompression", message)
            throw CompressionEngineError.outputValidationFailed
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let frameRate = try await videoTrack.load(.nominalFrameRate)
        let formatDescriptions = try await videoTrack.load(.formatDescriptions)
        guard formatDescriptions.count == 1, let formatDescription = formatDescriptions.first else {
            throw CompressionEngineError.outputValidationFailed
        }
        let formatExtensions = CMFormatDescriptionGetExtensions(formatDescription) as? [String: Any]
        let colorPrimaries = formatExtensions?[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
        let transferFunction = formatExtensions?[kCMFormatDescriptionExtension_TransferFunction as String] as? String
        let yCbCrMatrix = formatExtensions?[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let width = Int(abs(transformedRect.width).rounded())
        let height = Int(abs(transformedRect.height).rounded())
        let seconds = CMTimeGetSeconds(duration)
        guard width > 0, height > 0, seconds.isFinite, seconds > 0 else {
            let message = "Invalid video dimensions or duration at \(url.lastPathComponent)"
            AppLogger.shared.error("VideoCompression", message)
            throw CompressionEngineError.outputValidationFailed
        }
        return VideoFileProperties(
            asset: asset,
            duration: seconds,
            width: width,
            height: height,
            aspectRatio: Double(width) / Double(height),
            frameRate: Double(frameRate),
            colorPrimaries: colorPrimaries,
            transferFunction: transferFunction,
            yCbCrMatrix: yCbCrMatrix,
            audioTrackCount: audioTrackCount,
            otherTrackCount: otherTrackCount
        )
    }

    fileprivate static func fileIdentity(at url: URL) throws -> VideoFileIdentity {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let byteCount = (attributes[.size] as? NSNumber)?.int64Value,
              byteCount > 0,
              let modificationDate = attributes[.modificationDate] as? Date else {
            throw CompressionEngineError.outputSizeUnavailable
        }
        return VideoFileIdentity(byteCount: byteCount, modificationDate: modificationDate)
    }
}

private enum VideoCompressionPreparer {
    static func prepare(
        input: LocalCompressionInput,
        preset: CompressionPreset,
        workspace: CompressionWorkspace
    ) async throws -> VideoCompressionPreparation {
        try Task.checkCancellation()
        try input.verifySourceIsCurrent()
        guard inputIsVerified(input) else { return .skipped(.sourceSizeUnverified) }
        let identity = try VideoCompressionEngine.fileIdentity(at: input.sourceURL)
        guard identity.byteCount == input.verifiedSize.byteCount else {
            return .skipped(.sourceSizeMismatch)
        }
        let capabilities = await MediaCapabilityInspector.inspectVideo(at: input.sourceURL)
        guard capabilities == .supported else {
            return .skipped(.unsupportedSource(capabilities.logLabel))
        }
        let properties = try await VideoCompressionEngine.videoProperties(at: input.sourceURL)
        guard properties.frameRate.isFinite, properties.frameRate > 0 else {
            return .skipped(.unsupportedSource("The video frame rate could not be verified."))
        }
        guard let session = AVAssetExportSession(
            asset: properties.asset,
            presetName: preset.policy.videoExportPreset
        ), session.supportedFileTypes.contains(.mp4) else {
            return .skipped(.unsupportedVideoPreset("No compatible MPEG-4 export preset is available."))
        }
        let outputURL = workspace.outputDirectoryURL.appendingPathComponent("compressed-output.mp4")
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw CompressionEngineError.outputAlreadyExists
        }
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.videoComposition = try await VideoCompressionEngine.videoComposition(for: properties)
        session.shouldOptimizeForNetworkUse = true
        session.directoryForTemporaryFiles = workspace.outputDirectoryURL
        let job = VideoCompressionJob(
            sourceIdentity: identity,
            sourceProperties: properties,
            session: session,
            outputURL: outputURL
        )
        return .ready(job)
    }

    static func skipReason(for outcome: SavingsAssessment.Outcome) -> CompressionSkipReason {
        switch outcome {
        case .unverified: .sourceSizeUnverified
        case .notSmaller: .outputNotSmaller
        case .belowMinimum: .belowMinimumSavings
        case .qualifies: .outputNotSmaller
        }
    }

    private static func inputIsVerified(_ input: LocalCompressionInput) -> Bool {
        input.verifiedSize.byteCount > 0 &&
            !input.verifiedSize.assetID.isEmpty &&
            !input.verifiedSize.resourceSelectionBasis.isEmpty
    }
}

private enum VideoCompressionPreparation {
    case skipped(CompressionSkipReason)
    case ready(VideoCompressionJob)
}

private struct VideoCompressionJob {
    let sourceIdentity: VideoFileIdentity
    let sourceProperties: VideoFileProperties
    let session: AVAssetExportSession
    let outputURL: URL
}

private struct ValidatedVideoOutput {
    let identity: VideoFileIdentity
    let properties: VideoFileProperties
}

private struct VideoFileProperties {
    let asset: AVURLAsset
    let duration: Double
    let width: Int
    let height: Int
    let aspectRatio: Double
    let frameRate: Double
    let colorPrimaries: String?
    let transferFunction: String?
    let yCbCrMatrix: String?
    let audioTrackCount: Int
    let otherTrackCount: Int
}

private struct VideoFileIdentity: Equatable {
    let byteCount: Int64
    let modificationDate: Date
}

private final class VideoExportSessionHandle: @unchecked Sendable {
    let session: AVAssetExportSession

    init(session: AVAssetExportSession) {
        self.session = session
    }
}
