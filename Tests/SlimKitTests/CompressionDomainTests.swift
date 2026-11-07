import XCTest
@testable import SlimKit

final class CompressionDomainTests: XCTestCase {
    func testSavingsRequiresVerifiedSourceSize() {
        XCTAssertEqual(
            SavingsAssessment(source: .estimated(1_000), outputBytes: 800).outcome,
            .unverified
        )
        XCTAssertEqual(
            SavingsAssessment(source: .verified(1_000), outputBytes: 800).outcome,
            .qualifies(savedBytes: 200, fraction: 0.2)
        )
    }

    func testSavingsRejectsLargerAndInsignificantOutputs() {
        XCTAssertEqual(
            SavingsAssessment(source: .verified(1_000), outputBytes: 1_001).outcome,
            .notSmaller
        )
        XCTAssertEqual(
            SavingsAssessment(source: .verified(1_000), outputBytes: 960).outcome,
            .belowMinimum
        )
    }

    func testDeletionRequiresEverySafetyCondition() {
        var conditions = DeletionPreconditions(
            sourceIsEligible: true,
            sourceIsUnchanged: true,
            sourceBytesAreVerified: true,
            outputBytesAreVerified: true,
            outputIsSmallerByMinimum: true,
            outputWasValidated: true,
            replacementWasImported: true,
            replacementWasIndependentlyVerified: true,
            sourceIdentifierMatchesJob: true,
            replacementIdentifierIsKnown: true,
            userApprovedDeletion: true
        )
        XCTAssertTrue(conditions.canDeleteOriginal)

        conditions.userApprovedDeletion = false
        XCTAssertFalse(conditions.canDeleteOriginal)
        XCTAssertTrue(conditions.blockingReasons.contains("user has not approved deletion"))
    }

    func testEligibilityRequiresOnePlainOriginalResource() {
        XCTAssertEqual(
            MediaEligibilityClassifier.classify(
                kind: .photo,
                mediaSubtypeRawValue: 0,
                resources: [MediaResourceDescriptor(kind: .photo)]
            ),
            .inspectImageSource
        )
        XCTAssertEqual(
            MediaEligibilityClassifier.classify(
                kind: .video,
                mediaSubtypeRawValue: 0,
                resources: [MediaResourceDescriptor(kind: .video)]
            ),
            .inspectVideoSource
        )
        XCTAssertEqual(
            MediaEligibilityClassifier.classify(
                kind: .photo,
                mediaSubtypeRawValue: 1,
                resources: [MediaResourceDescriptor(kind: .photo)]
            ),
            .unsupported("Special media subtypes are not supported in the MVP.")
        )
        XCTAssertEqual(
            MediaEligibilityClassifier.classify(
                kind: .photo,
                mediaSubtypeRawValue: 0,
                resources: [
                    MediaResourceDescriptor(kind: .photo),
                    MediaResourceDescriptor(kind: .pairedVideo)
                ]
            ),
            .unsupported("The photo has paired, edited, auxiliary, or ambiguous resources.")
        )
    }

    func testUnverifiedSizeAndChangedSourceBlockDeletion() {
        var conditions = DeletionPreconditions(
            sourceIsEligible: true,
            sourceIsUnchanged: false,
            sourceBytesAreVerified: false,
            outputBytesAreVerified: false,
            outputIsSmallerByMinimum: false,
            outputWasValidated: true,
            replacementWasImported: true,
            replacementWasIndependentlyVerified: true,
            sourceIdentifierMatchesJob: true,
            replacementIdentifierIsKnown: true,
            userApprovedDeletion: true
        )
        XCTAssertFalse(conditions.canDeleteOriginal)
        XCTAssertTrue(conditions.blockingReasons.contains("source size is not verified"))
        XCTAssertTrue(conditions.blockingReasons.contains("source changed during processing"))
        XCTAssertTrue(conditions.blockingReasons.contains("output size is not verified"))

        conditions.sourceIsUnchanged = true
        conditions.sourceIsEligible = false
        XCTAssertFalse(conditions.canDeleteOriginal)
    }
}
