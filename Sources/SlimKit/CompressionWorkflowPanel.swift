import SwiftData
import SwiftUI

struct CompressionWorkflowPanel: View {
    let compressionResults: [CompressionQueueResult]
    let workflowRecords: [CompressionWorkflowRecord]
    let importStatusMessages: [String]
    let compressionStatusMessage: String?
    let deletionStatusMessage: String?
    let onImport: () -> Void
    let onReviewDeletion: (String) -> Void
    let onRetryVerification: (CompressionWorkflowSnapshot) -> Void
    let onRecoverDeletion: (String) -> Void

    private var hasCompressedResults: Bool {
        compressionResults.contains { result in
            if case let .compressed(artifact) = result.result {
                return artifact.hasCurrentSourceCheckpoint
            }
            return false
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header
                ForEach(compressionResults, id: \.assetID) { result in
                    compressionResultRow(result)
                }
                ForEach(workflowRecords, id: \.operationID) { record in
                    if let snapshot = try? record.snapshot() {
                        workflowRecordRow(snapshot)
                    } else {
                        Text("A saved workflow record could not be read. Do not retry its import or deletion.")
                            .foregroundStyle(.orange)
                    }
                }
                ForEach(Array(importStatusMessages.enumerated()), id: \.offset) { item in
                    Text(item.element)
                        .font(.caption)
                }
                if let compressionStatusMessage {
                    Text(compressionStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let deletionStatusMessage {
                    Text(deletionStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if hasCompressedResults {
                    Button("Import Compressed Results", action: onImport)
                }
                Text("Photos edits, favorites, albums, and relationship data are not copied. " +
                     "Originals remain untouched unless a later separate deletion confirmation is completed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.bar)
    }

    private var header: some View {
        HStack {
            Text("Compression Results")
                .font(.headline)
            Spacer()
            if !compressionResults.isEmpty {
                let summary = CompressionBatchSummary(results: compressionResults)
                Text("\(summary.completedCount) ready · \(summary.failedCount) failed · " +
                     "\(summary.skippedCount) skipped · \(summary.unchangedCount) unchanged · " +
                     "\(summary.sizeUnverifiedCount) size unverified")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func compressionResultRow(_ result: CompressionQueueResult) -> some View {
        switch result.result {
        case let .compressed(artifact):
            let readiness = artifact.hasCurrentSourceCheckpoint
                ? ""
                : " · source checkpoint unavailable; re-compress before import"
            Text("\(result.assetID): \(formatBytes(artifact.sourceBytes)) → " +
                 "\(formatBytes(artifact.outputBytes)) · " +
                 "\(String(format: "%.1f%%", artifact.savingsFraction * 100)) saved · \(format(artifact))\(readiness)")
                .font(.caption)
        case let .skipped(reason):
            Text("\(result.assetID): skipped · \(String(describing: reason))")
                .font(.caption)
        case let .failed(message):
            Text("\(result.assetID): failed · \(message)")
                .font(.caption)
                .foregroundStyle(.orange)
        case .cancelled:
            Text("\(result.assetID): cancelled")
                .font(.caption)
        }
    }

    private func workflowRecordRow(_ snapshot: CompressionWorkflowSnapshot) -> some View {
        let savedFraction = Double(snapshot.artifact.savedBytes) / Double(snapshot.artifact.sourceBytes)
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(snapshot.verifiedSource.assetID) → \(snapshot.replacementAssetID ?? "replacement pending") · " +
                 "\(formatBytes(snapshot.artifact.sourceBytes)) → " +
                 "\(formatBytes(snapshot.artifact.outputBytes)) · " +
                 "\(String(format: "%.1f%%", savedFraction * 100)) saved · " +
                 "\(format(snapshot.artifact)) · \(snapshot.phase.rawValue)")
                .font(.caption)
            if let errorMessage = snapshot.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if snapshot.phase == .awaitingDeletionDecision {
                Button("Review Original Deletion") {
                    onReviewDeletion(snapshot.operationID)
                }
            } else if snapshot.phase == .verifyingImport, snapshot.replacementAssetID != nil {
                Button("Retry Replacement Verification") {
                    onRetryVerification(snapshot)
                }
            } else if snapshot.phase == .deletingOriginal {
                Button("Reconcile Interrupted Deletion") {
                    onRecoverDeletion(snapshot.operationID)
                }
            }
        }
    }

    private func format(_ artifact: CompressedMediaArtifact) -> String {
        let codec = artifact.outputCodecIdentifier.map { " · \($0)" } ?? ""
        return "\(artifact.outputTypeIdentifier)\(codec) · \(artifact.pixelWidth)×\(artifact.pixelHeight) · " +
            artifact.preset.rawValue
    }

    private func formatBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
