import Foundation
import SwiftData
import SwiftUI

extension ContentView {
    func calculateSelectedSizes() {
        let assets = library.assets.filter { selectedIDs.contains($0.id) }
        guard !assets.isEmpty else { return }
        sizeStatusMessage = nil
        sizeTask = Task { @MainActor in await measureSelectedSizes(assets) }
    }

    func markSizeUnavailable(_ error: Error, for asset: MediaAsset) {
        if let resourceError = error as? ResourceExportError,
           case let .unsupported(reason) = resourceError {
            library.updateEligibility(.unsupported(reason), for: asset.id)
        } else {
            library.updateEligibility(.unavailable("The selected resource could not be verified."), for: asset.id)
        }
        AppLogger.shared.warning(
            "ResourceExport",
            "Selected resource not measured; error=\(error.localizedDescription)"
        )
    }

    func storeVerifiedSize(
        _ size: VerifiedResourceSize,
        capabilities: MediaCapabilityDecision,
        for asset: MediaAsset,
        recordsByID: inout [String: VerifiedSizeRecord]
    ) {
        if let record = recordsByID[asset.id] {
            record.update(with: size, capabilities: capabilities)
        } else {
            let record = VerifiedSizeRecord(size: size, capabilities: capabilities)
            modelContext.insert(record)
            recordsByID[asset.id] = record
        }
    }

    func toggleSelection(_ id: String) {
        sizeStatusMessage = nil
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    func setKept(_ isKept: Bool, for id: String) {
        AppLogger.shared.info("Review", "Keep state changed; kept=\(isKept)")
        let descriptor = FetchDescriptor<ReviewRecord>(predicate: #Predicate { $0.assetID == id })
        let existing = try? modelContext.fetch(descriptor).first
        if let existing {
            if isKept {
                existing.isKept = true
                existing.updatedAt = .now
            } else {
                modelContext.delete(existing)
            }
        } else if isKept {
            modelContext.insert(ReviewRecord(assetID: id, isKept: true))
        }
    }

    private func measureSelectedSizes(_ assets: [MediaAsset]) async {
        var recordsByID = sizeRecordsByID
        var measuredCount = 0
        var failureCount = 0
        for (index, asset) in assets.enumerated() {
            guard !Task.isCancelled else { break }
            sizeProgressMessage = "Exporting \(index + 1) of \(assets.count)"
            do {
                let measurement = try await PhotoResourceExporter.measure(
                    assetIdentifier: asset.id,
                    networkAccessAllowed: true
                )
                guard !Task.isCancelled else { break }
                storeVerifiedSize(
                    measurement.size,
                    capabilities: measurement.capabilities,
                    for: asset,
                    recordsByID: &recordsByID
                )
                library.applyCapabilityDecision(measurement.capabilities, for: asset.id)
                measuredCount += 1
            } catch is CancellationError {
                break
            } catch {
                markSizeUnavailable(error, for: asset)
                failureCount += 1
            }
        }
        finishSizeVerification(measuredCount: measuredCount, failureCount: failureCount)
    }

    private func finishSizeVerification(measuredCount: Int, failureCount: Int) {
        if Task.isCancelled {
            AppLogger.shared.info("ResourceExport", "Selected size verification cancelled")
        } else {
            sizeStatusMessage = "\(measuredCount) verified · \(failureCount) unavailable"
        }
        sizeProgressMessage = nil
        sizeTask = nil
    }
}
