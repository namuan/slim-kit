import Foundation

struct VerifiedResourceSize: Codable, Equatable, Sendable {
    let assetID: String
    let byteCount: Int64
    let sourceModificationDate: Date
    let resourceSelectionBasis: String
    let measuredAt: Date

    func isValid(for assetID: String, modificationDate: Date?, resourceSelectionBasis: String) -> Bool {
        guard byteCount > 0, let modificationDate else { return false }
        return self.assetID == assetID
            && sourceModificationDate == modificationDate
            && self.resourceSelectionBasis == resourceSelectionBasis
    }
}

struct VerifiedResourceMeasurement: Equatable, Sendable {
    let size: VerifiedResourceSize
    let capabilities: MediaCapabilityDecision
}

struct ResourceByteCounter: Equatable, Sendable {
    private(set) var streamedBytes: Int64 = 0

    mutating func append(_ count: Int) throws {
        guard count >= 0 else { throw ResourceExportError.invalidChunkSize }
        let (total, overflow) = streamedBytes.addingReportingOverflow(Int64(count))
        guard !overflow else { throw ResourceExportError.sizeOverflow }
        streamedBytes = total
    }

    func verifiedByteCount(fileByteCount: Int64) throws -> Int64 {
        guard fileByteCount >= 0, fileByteCount == streamedBytes else {
            throw ResourceExportError.byteCountMismatch
        }
        guard streamedBytes > 0 else { throw ResourceExportError.emptyResource }
        return streamedBytes
    }
}

enum ResourceExportError: LocalizedError, Equatable {
    case accessUnavailable
    case assetUnavailable
    case unsupported(String)
    case sourceStateUnavailable
    case sourceChanged
    case invalidChunkSize
    case sizeOverflow
    case byteCountMismatch
    case emptyResource
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .accessUnavailable: "Photos access is no longer available."
        case .assetUnavailable: "The Photos item is no longer accessible."
        case let .unsupported(reason): reason
        case .sourceStateUnavailable: "The source modification state cannot be verified."
        case .sourceChanged: "The source changed while its resource was being exported."
        case .invalidChunkSize: "The exported resource returned an invalid data chunk."
        case .sizeOverflow: "The exported resource is too large to count safely."
        case .byteCountMismatch: "The streamed byte count did not match the exported file."
        case .emptyResource: "The exported resource was empty."
        case .exportFailed: "Photos could not export the selected original resource."
        }
    }
}
