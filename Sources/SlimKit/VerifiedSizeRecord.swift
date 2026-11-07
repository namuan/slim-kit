import Foundation
import SwiftData

@Model
final class VerifiedSizeRecord {
    @Attribute(.unique) var assetID: String
    var byteCount: Int64
    var sourceModificationDate: Date
    var resourceSelectionBasis: String
    var measuredAt: Date

    init(size: VerifiedResourceSize) {
        assetID = size.assetID
        byteCount = size.byteCount
        sourceModificationDate = size.sourceModificationDate
        resourceSelectionBasis = size.resourceSelectionBasis
        measuredAt = size.measuredAt
    }

    func isValid(for asset: MediaAsset) -> Bool {
        byteCount > 0
            && assetID == asset.id
            && sourceModificationDate == asset.modificationDate
            && !resourceSelectionBasis.isEmpty
    }

    func update(with size: VerifiedResourceSize) {
        byteCount = size.byteCount
        sourceModificationDate = size.sourceModificationDate
        resourceSelectionBasis = size.resourceSelectionBasis
        measuredAt = size.measuredAt
    }
}
