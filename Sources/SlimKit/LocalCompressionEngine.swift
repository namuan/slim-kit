import Foundation
import ImageIO
import UniformTypeIdentifiers

struct LocalCompressionInput {
    let sourceURL: URL
    let verifiedSize: VerifiedResourceSize
    let verifySourceIsCurrent: () throws -> Void
}

enum CompressionAttempt: Equatable, Sendable {
    case compressed(CompressedMediaArtifact)
    case skipped(CompressionSkipReason)
}

enum CompressionSkipReason: Equatable, Sendable {
    case sourceSizeUnverified
    case sourceSizeMismatch
    case unsupportedSource(String)
    case unsupportedImageFormat(String)
    case unsupportedVideoPreset(String)
    case outputNotSmaller
    case unchanged
    case belowMinimumSavings
}

enum CompressionEngineError: LocalizedError, Equatable {
    case sourceChanged
    case imageSourceUnavailable
    case imageEncodingFailed
    case videoEncodingFailed
    case outputValidationFailed
    case outputAlreadyExists
    case outputSizeUnavailable

    var errorDescription: String? {
        switch self {
        case .sourceChanged: "The source changed during compression."
        case .imageSourceUnavailable: "The image source could not be opened."
        case .imageEncodingFailed: "The compressed image could not be encoded."
        case .videoEncodingFailed: "The compressed video could not be encoded."
        case .outputValidationFailed: "The compressed output did not pass validation."
        case .outputAlreadyExists: "The compression output path is already in use."
        case .outputSizeUnavailable: "The compressed output size could not be verified."
        }
    }
}

enum ImageCompressionEngine {
    static func compress(
        input: LocalCompressionInput,
        preset: CompressionPreset,
        workspace: CompressionWorkspace,
        progress: CompressionProgressHandler? = nil
    ) throws -> CompressionAttempt {
        try Task.checkCancellation()
        try input.verifySourceIsCurrent()
        guard hasVerifiedInput(input) else { return .skipped(.sourceSizeUnverified) }
        let initialIdentity = try sourceIdentity(at: input.sourceURL)
        guard initialIdentity.byteCount == input.verifiedSize.byteCount else {
            return .skipped(.sourceSizeMismatch)
        }
        let capabilities = MediaCapabilityInspector.inspectImage(at: input.sourceURL)
        guard capabilities == .supported else {
            return .skipped(.unsupportedSource(capabilities.logLabel))
        }
        let source: ImageCompressionSource
        switch try sourcePayload(at: input.sourceURL) {
        case let .ready(payload):
            source = payload
        case let .skipped(reason):
            return .skipped(reason)
        }
        let outputURL = outputURL(for: source.outputTypeIdentifier, workspace: workspace)
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw CompressionEngineError.outputAlreadyExists
        }
        var keepOutput = false
        defer {
            if !keepOutput { try? FileManager.default.removeItem(at: outputURL) }
        }
        progress?(.compressing, nil)
        try encode(source, preset: preset, to: outputURL)
        try Task.checkCancellation()
        progress?(.validating, nil)
        let output = try validatedOutput(
            input: input,
            initialIdentity: initialIdentity,
            source: source,
            preset: preset,
            outputURL: outputURL
        )
        try Task.checkCancellation()
        let assessment = SavingsAssessment(
            source: .verified(input.verifiedSize.byteCount),
            outputBytes: output.identity.byteCount,
            minimumReduction: preset.policy.minimumSavingsFraction
        )
        guard case let .qualifies(savedBytes, savingsFraction) = assessment.outcome else {
            return .skipped(skipReason(for: assessment.outcome))
        }
        let savings = VerifiedImageSavings(bytes: savedBytes, fraction: savingsFraction)
        let artifact = makeArtifact(input: input, preset: preset, source: source, output: output, savings: savings)
        keepOutput = true
        return .compressed(artifact)
    }

    private static func makeArtifact(
        input: LocalCompressionInput,
        preset: CompressionPreset,
        source: ImageCompressionSource,
        output: ImageCompressionOutput,
        savings: VerifiedImageSavings
    ) -> CompressedMediaArtifact {
        CompressedMediaArtifact(
            assetID: input.verifiedSize.assetID,
            preset: preset,
            sourceBytes: input.verifiedSize.byteCount,
            outputBytes: output.identity.byteCount,
            savedBytes: savings.bytes,
            savingsFraction: savings.fraction,
            outputTypeIdentifier: source.outputTypeIdentifier,
            outputCodecIdentifier: nil,
            pixelWidth: output.width,
            pixelHeight: output.height,
            videoDuration: nil,
            videoFrameRate: nil,
            outputURL: output.outputURL,
            verifiedSource: input.verifiedSize
        )
    }

    private static func hasVerifiedInput(_ input: LocalCompressionInput) -> Bool {
        input.verifiedSize.byteCount > 0 &&
            !input.verifiedSize.assetID.isEmpty &&
            !input.verifiedSize.resourceSelectionBasis.isEmpty
    }

    private static func sourcePayload(at url: URL) throws -> ImageSourcePreparation {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetCount(source) == 1,
              let sourceType = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return .skipped(.unsupportedImageFormat("Image properties could not be read."))
        }
        guard let outputTypeIdentifier = outputTypeIdentifier(for: sourceType) else {
            return .skipped(.unsupportedImageFormat("The image format has no compatible compression output."))
        }
        return .ready(
            ImageCompressionSource(
                imageSource: source,
                properties: properties,
                outputTypeIdentifier: outputTypeIdentifier
            )
        )
    }

    private static func outputURL(for typeIdentifier: String, workspace: CompressionWorkspace) -> URL {
        let fileExtension = UTType(typeIdentifier)?.preferredFilenameExtension ?? "image"
        return workspace.outputDirectoryURL
            .appendingPathComponent("compressed-output")
            .appendingPathExtension(fileExtension)
    }

    private static func encode(
        _ source: ImageCompressionSource,
        preset: CompressionPreset,
        to outputURL: URL
    ) throws {
        let type = UTType(source.outputTypeIdentifier)
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            source.outputTypeIdentifier as CFString,
            1,
            nil
        ), type != nil else {
            throw CompressionEngineError.imageEncodingFailed
        }
        var properties = source.properties
        properties[kCGImageDestinationLossyCompressionQuality as String] = preset.policy.imageQuality
        if let maximumDimension = preset.policy.maximumImageDimension {
            properties[kCGImageDestinationImageMaxPixelSize as String] = maximumDimension
        }
        CGImageDestinationAddImageFromSource(destination, source.imageSource, 0, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: outputURL)
            throw CompressionEngineError.imageEncodingFailed
        }
    }

    private static func validatedOutput(
        input: LocalCompressionInput,
        initialIdentity: CompressionFileIdentity,
        source: ImageCompressionSource,
        preset: CompressionPreset,
        outputURL: URL
    ) throws -> ImageCompressionOutput {
        try input.verifySourceIsCurrent()
        guard initialIdentity == (try sourceIdentity(at: input.sourceURL)) else {
            throw CompressionEngineError.sourceChanged
        }
        let identity = try sourceIdentity(at: outputURL)
        let outputSource = try decodedImageSource(at: outputURL, typeIdentifier: source.outputTypeIdentifier)
        let properties = try imageProperties(of: outputSource)
        let width = properties.width
        let height = properties.height
        guard orientation(in: source.properties) == orientation(in: properties.values),
              MediaCapabilityInspector.inspectImage(at: outputURL) == .supported,
              respectsMaximumDimension(width, height, preset: preset) else {
            throw CompressionEngineError.outputValidationFailed
        }
        return ImageCompressionOutput(identity: identity, width: width, height: height, outputURL: outputURL)
    }

    private static func decodedImageSource(at url: URL, typeIdentifier: String) throws -> CGImageSource {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == typeIdentifier,
              CGImageSourceCreateImageAtIndex(source, 0, options) != nil else {
            throw CompressionEngineError.outputValidationFailed
        }
        return source
    }

    private static func imageProperties(of source: CGImageSource) throws -> ImageProperties {
        guard let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = (values[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
              let height = (values[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            throw CompressionEngineError.outputValidationFailed
        }
        return ImageProperties(values: values, width: width, height: height)
    }

    private static func respectsMaximumDimension(
        _ width: Int,
        _ height: Int,
        preset: CompressionPreset
    ) -> Bool {
        guard let maximumDimension = preset.policy.maximumImageDimension else { return true }
        return max(width, height) <= maximumDimension
    }

    private static func skipReason(for outcome: SavingsAssessment.Outcome) -> CompressionSkipReason {
        switch outcome {
        case .unverified: .sourceSizeUnverified
        case .notSmaller: .outputNotSmaller
        case .unchanged: .unchanged
        case .belowMinimum: .belowMinimumSavings
        case .qualifies: .outputNotSmaller
        }
    }

    private static func outputTypeIdentifier(for sourceTypeIdentifier: String) -> String? {
        switch sourceTypeIdentifier {
        case UTType.jpeg.identifier, UTType.heic.identifier:
            sourceTypeIdentifier
        case UTType.png.identifier:
            UTType.jpeg.identifier
        default:
            nil
        }
    }

    private static func orientation(in properties: [String: Any]) -> Int {
        (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
    }

    private static func sourceIdentity(at url: URL) throws -> CompressionFileIdentity {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let byteCount = (attributes[.size] as? NSNumber)?.int64Value, byteCount > 0,
              let modificationDate = attributes[.modificationDate] as? Date else {
            throw CompressionEngineError.outputSizeUnavailable
        }
        return CompressionFileIdentity(byteCount: byteCount, modificationDate: modificationDate)
    }
}

private enum ImageSourcePreparation {
    case ready(ImageCompressionSource)
    case skipped(CompressionSkipReason)
}

private struct ImageCompressionSource {
    let imageSource: CGImageSource
    let properties: [String: Any]
    let outputTypeIdentifier: String
}

private struct ImageCompressionOutput {
    let identity: CompressionFileIdentity
    let width: Int
    let height: Int
    let outputURL: URL
}

private struct VerifiedImageSavings {
    let bytes: Int64
    let fraction: Double
}

private struct ImageProperties {
    let values: [String: Any]
    let width: Int
    let height: Int
}

private struct CompressionFileIdentity: Equatable {
    let byteCount: Int64
    let modificationDate: Date
}
