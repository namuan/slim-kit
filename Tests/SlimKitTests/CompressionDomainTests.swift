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

    func testResourceByteCountMatchesCompletedExport() throws {
        var counter = ResourceByteCounter()
        try counter.append(1_024)
        try counter.append(2_048)
        XCTAssertEqual(try counter.verifiedByteCount(fileByteCount: 3_072), 3_072)
        XCTAssertThrowsError(try counter.verifiedByteCount(fileByteCount: 3_071))
    }

    func testResourceByteCounterRejectsInvalidOrIncompleteResources() throws {
        let empty = ResourceByteCounter()
        XCTAssertThrowsError(try empty.verifiedByteCount(fileByteCount: 0))

        var invalid = ResourceByteCounter()
        XCTAssertThrowsError(try invalid.append(-1))

        var overflowing = ResourceByteCounter()
        try overflowing.append(Int.max)
        XCTAssertThrowsError(try overflowing.append(1))
    }

    func testResourceExportCancellationCancelsRequestInstalledAfterward() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        guard let fileHandle = try? FileHandle(forWritingTo: url) else {
            XCTFail("Could not create temporary test file")
            return
        }
        defer {
            try? fileHandle.close()
            try? FileManager.default.removeItem(at: url)
        }
        let recorder = RequestCancellationRecorder()
        let operation = ResourceExportOperation(fileHandle: fileHandle) {
            recorder.record($0)
        }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                operation.setContinuation(continuation)
                operation.cancel()
                operation.install(requestID: 17)
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(recorder.requestIDs, [17])
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testVerifiedSizeCacheRequiresMatchingSourceAndResourceBasis() {
        let modifiedAt = Date(timeIntervalSince1970: 1_000)
        let size = VerifiedResourceSize(
            assetID: "asset-1",
            byteCount: 4_096,
            sourceModificationDate: modifiedAt,
            resourceSelectionBasis: "photo|public.jpeg",
            measuredAt: modifiedAt
        )
        XCTAssertTrue(size.isValid(
            for: "asset-1",
            modificationDate: modifiedAt,
            resourceSelectionBasis: "photo|public.jpeg"
        ))
        XCTAssertFalse(size.isValid(
            for: "asset-1",
            modificationDate: modifiedAt.addingTimeInterval(1),
            resourceSelectionBasis: "photo|public.jpeg"
        ))
        XCTAssertFalse(size.isValid(
            for: "asset-1",
            modificationDate: modifiedAt,
            resourceSelectionBasis: "video|public.mpeg-4"
        ))
        XCTAssertFalse(size.isValid(
            for: "asset-1",
            modificationDate: nil,
            resourceSelectionBasis: "photo|public.jpeg"
        ))
    }
}

private final class RequestCancellationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int32] = []

    var requestIDs: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ requestID: Int32) {
        lock.lock()
        storage.append(requestID)
        lock.unlock()
    }
}
