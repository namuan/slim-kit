import Foundation

enum MediaSizeState: Equatable, Sendable {
    case unknown
    case estimated(Int64)
    case verified(Int64)
    case unavailable(String)

    var verifiedBytes: Int64? {
        guard case let .verified(bytes) = self, bytes >= 0 else { return nil }
        return bytes
    }
}

enum CompressionPreset: String, CaseIterable, Codable, Sendable {
    case highQuality
    case balanced
    case maximumSavings
}

enum CompressionPhase: String, Codable, CaseIterable, Sendable {
    case pending
    case downloading
    case compressing
    case validating
    case importing
    case verifyingImport
    case awaitingDeletionDecision
    case deletingOriginal
    case completed
    case skipped
    case failed
    case cancelled
    case needsReview
}

struct SavingsAssessment: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case unverified
        case notSmaller
        case belowMinimum
        case qualifies(savedBytes: Int64, fraction: Double)
    }

    let outcome: Outcome

    init(source: MediaSizeState, outputBytes: Int64, minimumReduction: Double = 0.05) {
        guard let sourceBytes = source.verifiedBytes, outputBytes >= 0, sourceBytes > 0 else {
            outcome = .unverified
            return
        }
        guard outputBytes < sourceBytes else {
            outcome = .notSmaller
            return
        }
        let savedBytes = sourceBytes - outputBytes
        let fraction = Double(savedBytes) / Double(sourceBytes)
        guard fraction >= minimumReduction else {
            outcome = .belowMinimum
            return
        }
        outcome = .qualifies(savedBytes: savedBytes, fraction: fraction)
    }
}

struct DeletionPreconditions: Equatable, Sendable {
    var sourceIsEligible: Bool
    var sourceIsUnchanged: Bool
    var sourceBytesAreVerified: Bool
    var outputBytesAreVerified: Bool
    var outputIsSmallerByMinimum: Bool
    var outputWasValidated: Bool
    var replacementWasImported: Bool
    var replacementWasIndependentlyVerified: Bool
    var sourceIdentifierMatchesJob: Bool
    var replacementIdentifierIsKnown: Bool
    var userApprovedDeletion: Bool

    var canDeleteOriginal: Bool {
        blockingReasons.isEmpty
    }

    var blockingReasons: [String] {
        var reasons: [String] = []
        if !sourceIsEligible { reasons.append("source is not eligible") }
        if !sourceIsUnchanged { reasons.append("source changed during processing") }
        if !sourceBytesAreVerified { reasons.append("source size is not verified") }
        if !outputBytesAreVerified { reasons.append("output size is not verified") }
        if !outputIsSmallerByMinimum { reasons.append("output does not meet the minimum reduction") }
        if !outputWasValidated { reasons.append("output validation did not pass") }
        if !replacementWasImported { reasons.append("replacement was not imported") }
        if !replacementWasIndependentlyVerified { reasons.append("replacement verification did not pass") }
        if !sourceIdentifierMatchesJob { reasons.append("source identifier does not match the job") }
        if !replacementIdentifierIsKnown { reasons.append("replacement identifier is unknown") }
        if !userApprovedDeletion { reasons.append("user has not approved deletion") }
        return reasons
    }
}
