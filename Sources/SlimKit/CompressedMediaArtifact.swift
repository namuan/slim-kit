import Foundation

struct CompressedMediaArtifact: Codable, Equatable, Sendable {
    let assetID: String
    let preset: CompressionPreset
    let sourceBytes: Int64
    let outputBytes: Int64
    let savedBytes: Int64
    let savingsFraction: Double
    let outputTypeIdentifier: String
    let outputCodecIdentifier: String?
    let pixelWidth: Int
    let pixelHeight: Int
    let videoDuration: Double?
    let videoFrameRate: Double?
    let outputURL: URL
    let verifiedSource: VerifiedResourceSize

    var operationID: String {
        outputURL.deletingLastPathComponent().lastPathComponent
    }

    var hasCurrentSourceCheckpoint: Bool {
        verifiedSource.assetID == assetID &&
            verifiedSource.byteCount == sourceBytes &&
            verifiedSource.byteCount > 0 &&
            verifiedSource.sourceModificationDate != .distantPast &&
            verifiedSource.measuredAt != .distantPast &&
            !verifiedSource.resourceSelectionBasis.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case assetID
        case preset
        case sourceBytes
        case outputBytes
        case savedBytes
        case savingsFraction
        case outputTypeIdentifier
        case outputCodecIdentifier
        case pixelWidth
        case pixelHeight
        case videoDuration
        case videoFrameRate
        case outputURL
        case verifiedSource
    }

    init(
        assetID: String,
        preset: CompressionPreset,
        sourceBytes: Int64,
        outputBytes: Int64,
        savedBytes: Int64,
        savingsFraction: Double,
        outputTypeIdentifier: String,
        outputCodecIdentifier: String?,
        pixelWidth: Int,
        pixelHeight: Int,
        videoDuration: Double?,
        videoFrameRate: Double?,
        outputURL: URL,
        verifiedSource: VerifiedResourceSize
    ) {
        self.assetID = assetID
        self.preset = preset
        self.sourceBytes = sourceBytes
        self.outputBytes = outputBytes
        self.savedBytes = savedBytes
        self.savingsFraction = savingsFraction
        self.outputTypeIdentifier = outputTypeIdentifier
        self.outputCodecIdentifier = outputCodecIdentifier
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.videoDuration = videoDuration
        self.videoFrameRate = videoFrameRate
        self.outputURL = outputURL
        self.verifiedSource = verifiedSource
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assetID = try container.decode(String.self, forKey: .assetID)
        preset = try container.decode(CompressionPreset.self, forKey: .preset)
        sourceBytes = try container.decode(Int64.self, forKey: .sourceBytes)
        outputBytes = try container.decode(Int64.self, forKey: .outputBytes)
        savedBytes = try container.decode(Int64.self, forKey: .savedBytes)
        savingsFraction = try container.decode(Double.self, forKey: .savingsFraction)
        outputTypeIdentifier = try container.decode(String.self, forKey: .outputTypeIdentifier)
        outputCodecIdentifier = try container.decodeIfPresent(String.self, forKey: .outputCodecIdentifier)
        pixelWidth = try container.decode(Int.self, forKey: .pixelWidth)
        pixelHeight = try container.decode(Int.self, forKey: .pixelHeight)
        videoDuration = try container.decodeIfPresent(Double.self, forKey: .videoDuration)
        videoFrameRate = try container.decodeIfPresent(Double.self, forKey: .videoFrameRate)
        outputURL = try container.decode(URL.self, forKey: .outputURL)
        verifiedSource = try container.decodeIfPresent(VerifiedResourceSize.self, forKey: .verifiedSource) ??
            VerifiedResourceSize(
                assetID: assetID,
                byteCount: sourceBytes,
                sourceModificationDate: .distantPast,
                resourceSelectionBasis: "",
                measuredAt: .distantPast
            )
    }
}
