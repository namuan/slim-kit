import Foundation
import SwiftData

struct CompressionWorkflowSnapshot: Codable, Equatable, Sendable {
    let operationID: String
    let mediaKind: MediaAsset.Kind
    let verifiedSource: VerifiedResourceSize
    let artifact: CompressedMediaArtifact
    let importMetadata: CompressionImportMetadata
    let phase: CompressionPhase
    let replacementAssetID: String?
    let errorMessage: String?
    let createdAt: Date
    let updatedAt: Date
    let deletionRequested: Bool
    let deletionApprovalRecorded: Bool
    let deletionTransactionSucceeded: Bool

    init(
        operationID: String = UUID().uuidString,
        mediaKind: MediaAsset.Kind,
        verifiedSource: VerifiedResourceSize,
        artifact: CompressedMediaArtifact,
        importMetadata: CompressionImportMetadata,
        phase: CompressionPhase,
        replacementAssetID: String? = nil,
        errorMessage: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        deletionRequested: Bool = false,
        deletionApprovalRecorded: Bool = false,
        deletionTransactionSucceeded: Bool = false
    ) {
        self.operationID = operationID
        self.mediaKind = mediaKind
        self.verifiedSource = verifiedSource
        self.artifact = artifact
        self.importMetadata = importMetadata
        self.phase = phase
        self.replacementAssetID = replacementAssetID
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletionRequested = deletionRequested
        self.deletionApprovalRecorded = deletionApprovalRecorded
        self.deletionTransactionSucceeded = deletionTransactionSucceeded
    }

    func updating(
        phase: CompressionPhase,
        replacementAssetID: String? = nil,
        errorMessage: String? = nil,
        deletionRequested: Bool? = nil,
        deletionApprovalRecorded: Bool? = nil,
        deletionTransactionSucceeded: Bool? = nil
    ) -> CompressionWorkflowSnapshot {
        CompressionWorkflowSnapshot(
            operationID: operationID,
            mediaKind: mediaKind,
            verifiedSource: verifiedSource,
            artifact: artifact,
            importMetadata: importMetadata,
            phase: phase,
            replacementAssetID: replacementAssetID ?? self.replacementAssetID,
            errorMessage: errorMessage,
            createdAt: createdAt,
            updatedAt: .now,
            deletionRequested: deletionRequested ?? self.deletionRequested,
            deletionApprovalRecorded: deletionApprovalRecorded ?? self.deletionApprovalRecorded,
            deletionTransactionSucceeded: deletionTransactionSucceeded ?? self.deletionTransactionSucceeded
        )
    }
}

@Model
final class CompressionWorkflowRecord {
    @Attribute(.unique) var operationID: String
    var snapshotData: Data

    init(snapshot: CompressionWorkflowSnapshot) throws {
        operationID = snapshot.operationID
        snapshotData = try JSONEncoder().encode(snapshot)
    }

    func update(with snapshot: CompressionWorkflowSnapshot) throws {
        snapshotData = try JSONEncoder().encode(snapshot)
    }

    func snapshot() throws -> CompressionWorkflowSnapshot {
        try JSONDecoder().decode(CompressionWorkflowSnapshot.self, from: snapshotData)
    }
}

@MainActor
protocol CompressionWorkflowCheckpointing {
    func save(_ snapshot: CompressionWorkflowSnapshot) throws
    func snapshot(operationID: String) throws -> CompressionWorkflowSnapshot?
    func allSnapshots() throws -> [CompressionWorkflowSnapshot]
}

@MainActor
final class SwiftDataCompressionWorkflowStore: CompressionWorkflowCheckpointing {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func save(_ snapshot: CompressionWorkflowSnapshot) throws {
        let operationID = snapshot.operationID
        let descriptor = FetchDescriptor<CompressionWorkflowRecord>(
            predicate: #Predicate { $0.operationID == operationID }
        )
        if let record = try modelContext.fetch(descriptor).first {
            try record.update(with: snapshot)
        } else {
            modelContext.insert(try CompressionWorkflowRecord(snapshot: snapshot))
        }
        try modelContext.save()
    }

    func snapshot(operationID: String) throws -> CompressionWorkflowSnapshot? {
        let descriptor = FetchDescriptor<CompressionWorkflowRecord>(
            predicate: #Predicate { $0.operationID == operationID }
        )
        return try modelContext.fetch(descriptor).first?.snapshot()
    }

    func allSnapshots() throws -> [CompressionWorkflowSnapshot] {
        try modelContext.fetch(FetchDescriptor<CompressionWorkflowRecord>())
            .map { try $0.snapshot() }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}
