import Foundation

enum LibrarySortOrder: String, CaseIterable, Hashable, Identifiable {
    case newest = "Newest"
    case largestVerified = "Largest verified"
    case longestVideo = "Longest video"

    var id: String { rawValue }
}

enum MediaAssetSorter {
    static func sorted(
        _ assets: [MediaAsset],
        by order: LibrarySortOrder,
        sizeRecords: [String: VerifiedSizeRecord]
    ) -> [MediaAsset] {
        assets.enumerated().sorted { left, right in
            switch order {
            case .newest:
                return precedes(
                    left.element.creationDate,
                    right.element.creationDate,
                    leftIndex: left.offset,
                    rightIndex: right.offset
                )
            case .largestVerified:
                return precedes(
                    verifiedBytes(for: left.element, records: sizeRecords),
                    verifiedBytes(for: right.element, records: sizeRecords),
                    leftIndex: left.offset,
                    rightIndex: right.offset
                )
            case .longestVideo:
                return precedes(
                    left.element.duration,
                    right.element.duration,
                    leftIndex: left.offset,
                    rightIndex: right.offset
                )
            }
        }.map(\.element)
    }

    private static func verifiedBytes(
        for asset: MediaAsset,
        records: [String: VerifiedSizeRecord]
    ) -> Int64? {
        guard let record = records[asset.id], record.isValid(for: asset) else { return nil }
        return record.byteCount
    }

    private static func precedes<Value: Comparable>(
        _ leftValue: Value?,
        _ rightValue: Value?,
        leftIndex: Int,
        rightIndex: Int
    ) -> Bool {
        if let leftValue, let rightValue, leftValue != rightValue {
            return leftValue > rightValue
        }
        if (leftValue == nil) != (rightValue == nil) {
            return leftValue != nil
        }
        return leftIndex < rightIndex
    }
}
