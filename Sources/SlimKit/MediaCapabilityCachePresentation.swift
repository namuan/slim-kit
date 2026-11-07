import Foundation

enum MediaSizePresentation {
    static func label(for asset: MediaAsset, record: VerifiedSizeRecord?) -> String {
        guard let record, record.isValid(for: asset) else { return "Size not calculated" }
        return "\(ByteCountFormatter.string(fromByteCount: record.byteCount, countStyle: .file)) · verified"
    }
}

@MainActor
final class MediaCapabilityCacheLogger {
    private var loggedAssetIDs = Set<String>()

    func recordRestorations(for assets: [MediaAsset], records: [String: VerifiedSizeRecord]) {
        for asset in assets {
            guard let decision = MediaCapabilityCachePresentation.decision(
                for: asset,
                record: records[asset.id]
            ), loggedAssetIDs.insert(asset.id).inserted else { continue }
            AppLogger.shared.info(
                "CapabilityCache",
                "Restored persisted capability; kind=\(asset.kind.rawValue); outcome=\(decision.logLabel)"
            )
        }
    }
}

enum MediaCapabilityCachePresentation {
    static func asset(for asset: MediaAsset, record: VerifiedSizeRecord?) -> MediaAsset {
        guard let decision = decision(for: asset, record: record) else { return asset }
        var displayedAsset = asset
        displayedAsset.eligibility = MediaEligibilityClassifier.apply(decision)
        return displayedAsset
    }

    static func decision(for asset: MediaAsset, record: VerifiedSizeRecord?) -> MediaCapabilityDecision? {
        MediaCapabilityCacheRestorer.decision(
            eligibility: asset.eligibility,
            assetID: asset.id,
            sourceModificationDate: asset.modificationDate,
            record: record
        )
    }
}
