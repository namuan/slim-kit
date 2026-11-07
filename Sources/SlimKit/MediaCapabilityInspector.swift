import AVFoundation
import CoreMedia
import CoreVideo
import ImageIO

struct ImageSourceCapabilities: Equatable, Sendable {
    let typeIdentifier: String?
    let frameCount: Int
    let hasAlpha: Bool?
    let bitDepth: Int?
    let colorProfile: String?
    let exifColorSpace: Int?
    let auxiliaryDataTypes: [String]
}

struct VideoSourceCapabilities: Equatable, Sendable {
    let isPlayable: Bool
    let hasValidDuration: Bool
    let videoTrackCount: Int
    let audioTrackCount: Int
    let otherTrackCount: Int
    let videoCodecType: FourCharCode?
    let colorPrimaries: String?
    let transferFunction: String?
    let logTransferFunction: String?
}

struct MediaCapabilityCacheIdentity: Equatable, Sendable {
    let sourceModificationDate: Date
    let resourceSelectionBasis: String
    let inspectorVersion: Int

    func matches(
        sourceModificationDate: Date?,
        resourceSelectionBasis: String,
        inspectorVersion: Int
    ) -> Bool {
        self.sourceModificationDate == sourceModificationDate
            && self.resourceSelectionBasis == resourceSelectionBasis
            && self.inspectorVersion == inspectorVersion
            && !resourceSelectionBasis.isEmpty
    }
}

enum MediaCapabilityDecision: Equatable, Sendable {
    case supported
    case unsupported(String)
    case uncertain(String)

    var persistenceStatus: String {
        switch self {
        case .supported:
            "supported"
        case .unsupported:
            "unsupported"
        case .uncertain:
            "uncertain"
        }
    }

    var persistenceReason: String? {
        switch self {
        case .supported:
            nil
        case let .unsupported(reason), let .uncertain(reason):
            reason
        }
    }

    static func restore(status: String?, reason: String?, inspectorVersion: Int?) -> Self? {
        guard inspectorVersion == MediaCapabilityInspector.version, let status else { return nil }
        switch status {
        case "supported":
            return .supported
        case "unsupported":
            guard let reason else { return nil }
            return .unsupported(reason)
        case "uncertain":
            guard let reason else { return nil }
            return .uncertain(reason)
        default:
            return nil
        }
    }

    var logLabel: String {
        switch self {
        case .supported:
            "supported"
        case let .unsupported(reason):
            "unsupported: \(reason)"
        case let .uncertain(reason):
            "uncertain: \(reason)"
        }
    }
}

private struct VideoFormatCapabilities {
    let codecType: FourCharCode
    let colorPrimaries: String?
    let transferFunction: String?
    let logTransferFunction: String?
}

private enum MediaCapabilityInspectionFailure: Error {
    case ambiguousVideoFormat
}

enum MediaCapabilityInspector {
    static let version = 1

    static func inspectImage(at url: URL) -> MediaCapabilityDecision {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return .uncertain("Image metadata could not be read.")
        }
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let auxiliaryDataTypes = auxiliaryDataTypes(source: source, properties: properties)
        let capabilities = ImageSourceCapabilities(
            typeIdentifier: CGImageSourceGetType(source) as String?,
            frameCount: CGImageSourceGetCount(source),
            hasAlpha: properties[kCGImagePropertyHasAlpha as String] as? Bool,
            bitDepth: (properties[kCGImagePropertyDepth as String] as? NSNumber)?.intValue,
            colorProfile: properties[kCGImagePropertyProfileName as String] as? String,
            exifColorSpace: (exif?[kCGImagePropertyExifColorSpace as String] as? NSNumber)?.intValue,
            auxiliaryDataTypes: auxiliaryDataTypes
        )
        return assessImage(capabilities)
    }

    static func assessImage(_ capabilities: ImageSourceCapabilities) -> MediaCapabilityDecision {
        guard capabilities.frameCount == 1 else {
            return .unsupported("Multi-frame or animated images are not supported.")
        }
        guard let typeIdentifier = capabilities.typeIdentifier else {
            return .uncertain("The image format could not be identified.")
        }
        guard ["public.jpeg", "public.heic", "public.png"].contains(typeIdentifier) else {
            return .unsupported("The image format is not supported for compression.")
        }
        guard capabilities.auxiliaryDataTypes.isEmpty else {
            let dataTypes = capabilities.auxiliaryDataTypes.joined(separator: ", ")
            return .unsupported("The image contains auxiliary data: \(dataTypes).")
        }
        if capabilities.hasAlpha == true {
            return .unsupported("Transparent images are not supported by the current output policy.")
        }
        guard let bitDepth = capabilities.bitDepth else {
            return .uncertain("Image bit depth could not be determined.")
        }
        guard bitDepth <= 8 else {
            return .unsupported("High-bit-depth images are not supported.")
        }
        let profile = capabilities.colorProfile?.lowercased()
        if let profile, isWideGamut(profile) {
            return .unsupported("Wide-gamut images are not supported by the current output policy.")
        }
        if profile?.contains("srgb") == true || capabilities.exifColorSpace == 1 {
            return .supported
        }
        return .uncertain("The image color profile is missing or unrecognized.")
    }

    static func inspectVideo(at url: URL) async -> MediaCapabilityDecision {
        do {
            return assessVideo(try await readVideoCapabilities(at: url))
        } catch {
            return .uncertain("Video track metadata could not be read.")
        }
    }

    private static func readVideoCapabilities(at url: URL) async throws -> VideoSourceCapabilities {
        let asset = AVURLAsset(url: url)
        let isPlayable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.load(.tracks)
        let videoTracks = tracks.filter { $0.mediaType == .video }
        let audioTracks = tracks.filter { $0.mediaType == .audio }
        let otherTrackCount = tracks.count - videoTracks.count - audioTracks.count
        guard let videoTrack = videoTracks.first else {
            return VideoSourceCapabilities(
                isPlayable: isPlayable,
                hasValidDuration: false,
                videoTrackCount: videoTracks.count,
                audioTrackCount: audioTracks.count,
                otherTrackCount: otherTrackCount,
                videoCodecType: nil,
                colorPrimaries: nil,
                transferFunction: nil,
                logTransferFunction: nil
            )
        }
        let format = try await readVideoFormat(for: videoTrack)
        return VideoSourceCapabilities(
            isPlayable: isPlayable,
            hasValidDuration: CMTimeGetSeconds(duration).isFinite && CMTimeGetSeconds(duration) > 0,
            videoTrackCount: videoTracks.count,
            audioTrackCount: audioTracks.count,
            otherTrackCount: otherTrackCount,
            videoCodecType: format.codecType,
            colorPrimaries: format.colorPrimaries,
            transferFunction: format.transferFunction,
            logTransferFunction: format.logTransferFunction
        )
    }

    private static func readVideoFormat(for track: AVAssetTrack) async throws -> VideoFormatCapabilities {
        let descriptions = try await track.load(.formatDescriptions)
        guard descriptions.count == 1, let description = descriptions.first else {
            throw MediaCapabilityInspectionFailure.ambiguousVideoFormat
        }
        let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any]
        let logTransferFunction = logTransferFunction(in: extensions)
        return VideoFormatCapabilities(
            codecType: CMFormatDescriptionGetMediaSubType(description),
            colorPrimaries: extensions?[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String,
            transferFunction: extensions?[kCMFormatDescriptionExtension_TransferFunction as String] as? String,
            logTransferFunction: logTransferFunction
        )
    }

    static func assessVideo(_ capabilities: VideoSourceCapabilities) -> MediaCapabilityDecision {
        guard capabilities.isPlayable else {
            return .unsupported("The video source is not playable.")
        }
        guard capabilities.hasValidDuration else {
            return .unsupported("The video duration is missing or invalid.")
        }
        guard capabilities.videoTrackCount == 1 else {
            return .unsupported("The video must contain exactly one video track.")
        }
        guard capabilities.audioTrackCount <= 1, capabilities.otherTrackCount == 0 else {
            return .unsupported("Multiple audio tracks or additional timed tracks are not supported.")
        }
        guard let videoCodecType = capabilities.videoCodecType else {
            return .uncertain("The video codec could not be identified.")
        }
        guard videoCodecType == kCMVideoCodecType_H264 || videoCodecType == kCMVideoCodecType_HEVC else {
            return .unsupported("The video codec is not supported for compression.")
        }
        return assessVideoColor(
            colorPrimaries: capabilities.colorPrimaries,
            transferFunction: capabilities.transferFunction,
            logTransferFunction: capabilities.logTransferFunction
        )
    }

    private static func assessVideoColor(
        colorPrimaries: String?,
        transferFunction: String?,
        logTransferFunction: String?
    ) -> MediaCapabilityDecision {
        if logTransferFunction != nil {
            return .unsupported("Log-encoded video is not supported.")
        }
        guard let colorPrimaries = colorPrimaries?.lowercased(),
              let transferFunction = transferFunction?.lowercased() else {
            return .uncertain("Video color metadata is missing.")
        }
        if isWideGamut(colorPrimaries) {
            return .unsupported("Wide-gamut video is not supported by the current output policy.")
        }
        if isHDRTransferFunction(transferFunction) {
            return .unsupported("HDR video is not supported by the current output policy.")
        }
        guard isStandardDefinitionColor(colorPrimaries), isStandardSDRTransferFunction(transferFunction) else {
            return .uncertain("Video color metadata is unrecognized.")
        }
        return .supported
    }

    private static func logTransferFunction(in extensions: [String: Any]?) -> String? {
        guard #available(macOS 14.2, *) else { return nil }
        let key = kCMFormatDescriptionExtension_LogTransferFunction as String
        return extensions?[key] as? String
    }

    private static func auxiliaryDataTypes(source: CGImageSource, properties: [String: Any]) -> [String] {
        var knownTypes: [CFString] = [
            kCGImageAuxiliaryDataTypeDepth,
            kCGImageAuxiliaryDataTypeDisparity,
            kCGImageAuxiliaryDataTypePortraitEffectsMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte,
            kCGImageAuxiliaryDataTypeHDRGainMap
        ]
        if #available(macOS 14.1, *) {
            knownTypes.append(kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte)
        }
        if #available(macOS 15.0, *) {
            knownTypes.append(kCGImageAuxiliaryDataTypeISOGainMap)
        }
        var result = knownTypes.compactMap { type in
            CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) == nil ? nil : type as String
        }
        let propertyTypes = (properties[kCGImagePropertyAuxiliaryData as String] as? [[String: Any]])?
            .compactMap { $0[kCGImagePropertyAuxiliaryDataType as String] as? String } ?? []
        result.append(contentsOf: propertyTypes)
        return Array(Set(result)).sorted()
    }

    private static func isWideGamut(_ value: String) -> Bool {
        ["p3", "2020", "adobe rgb", "prophoto", "romm"].contains(where: value.contains)
    }

    private static func isHDRTransferFunction(_ value: String) -> Bool {
        value.contains("2084") || value.contains("pq") || value.contains("2100") || value.contains("hlg")
    }

    private static func isStandardDefinitionColor(_ value: String) -> Bool {
        ["709", "smpte-c", "ebu 3213"].contains(where: value.contains)
    }

    private static func isStandardSDRTransferFunction(_ value: String) -> Bool {
        ["709", "srgb", "240m"].contains(where: value.contains)
    }
}
