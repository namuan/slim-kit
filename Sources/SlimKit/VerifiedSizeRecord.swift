import Foundation
import SwiftData

@Model
final class VerifiedSizeRecord {
    @Attribute(.unique) var assetID: String
    var byteCount: Int64
    var sourceModificationDate: Date
    var resourceSelectionBasis: String
    var measuredAt: Date
    var capabilityStatus: String?
    var capabilityReason: String?
    var capabilitySourceModificationDate: Date?
    var capabilityResourceSelectionBasis: String?
    var capabilityInspectorVersion: Int?

    init(size: VerifiedResourceSize, capabilities: MediaCapabilityDecision) {
        assetID = size.assetID
        byteCount = size.byteCount
        sourceModificationDate = size.sourceModificationDate
        resourceSelectionBasis = size.resourceSelectionBasis
        measuredAt = size.measuredAt
        capabilityStatus = capabilities.persistenceStatus
        capabilityReason = capabilities.persistenceReason
        capabilitySourceModificationDate = size.sourceModificationDate
        capabilityResourceSelectionBasis = size.resourceSelectionBasis
        capabilityInspectorVersion = MediaCapabilityInspector.version
    }

    func isValid(for asset: MediaAsset) -> Bool {
        byteCount > 0
            && assetID == asset.id
            && sourceModificationDate == asset.modificationDate
            && !resourceSelectionBasis.isEmpty
    }

    func capabilityDecision(for asset: MediaAsset) -> MediaCapabilityDecision? {
        guard isValid(for: asset) else { return nil }
        return capabilityDecision(
            sourceModificationDate: asset.modificationDate,
            resourceSelectionBasis: resourceSelectionBasis
        )
    }

    func capabilityDecision(
        sourceModificationDate: Date?,
        resourceSelectionBasis: String
    ) -> MediaCapabilityDecision? {
        guard let capabilitySourceModificationDate,
              let capabilityResourceSelectionBasis,
              let capabilityInspectorVersion else { return nil }
        let identity = MediaCapabilityCacheIdentity(
            sourceModificationDate: capabilitySourceModificationDate,
            resourceSelectionBasis: capabilityResourceSelectionBasis,
            inspectorVersion: capabilityInspectorVersion
        )
        guard identity.matches(
            sourceModificationDate: sourceModificationDate,
            resourceSelectionBasis: resourceSelectionBasis,
            inspectorVersion: MediaCapabilityInspector.version
        ) else { return nil }
        return MediaCapabilityDecision.restore(
            status: capabilityStatus,
            reason: capabilityReason,
            inspectorVersion: capabilityInspectorVersion
        )
    }

    func update(with size: VerifiedResourceSize, capabilities: MediaCapabilityDecision) {
        byteCount = size.byteCount
        sourceModificationDate = size.sourceModificationDate
        resourceSelectionBasis = size.resourceSelectionBasis
        measuredAt = size.measuredAt
        capabilityStatus = capabilities.persistenceStatus
        capabilityReason = capabilities.persistenceReason
        capabilitySourceModificationDate = size.sourceModificationDate
        capabilityResourceSelectionBasis = size.resourceSelectionBasis
        capabilityInspectorVersion = MediaCapabilityInspector.version
    }
}
