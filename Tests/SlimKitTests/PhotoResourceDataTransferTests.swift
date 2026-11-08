import Foundation
import Photos
import XCTest
@testable import SlimKit

final class PhotoResourceDataTransferTests: XCTestCase {
    func testTransferForwardsNetworkOptionAndVerifiesStreamedBytes() async throws {
        let (url, fileHandle) = try makeFile()
        defer {
            try? fileHandle.close()
            try? FileManager.default.removeItem(at: url)
        }
        let requester = StubResourceDataRequester(chunks: [Data([1, 2]), Data([3, 4])])
        let progressRecorder = TransferProgressRecorder()

        let byteCount = try await PhotoResourceExporter.transfer(
            using: requester,
            to: fileHandle,
            at: url,
            networkAccessAllowed: true,
            progress: { progressRecorder.record($0) }
        )

        XCTAssertEqual(byteCount, 4)
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3, 4]))
        XCTAssertEqual(requester.networkAccessAllowed, true)
        XCTAssertEqual(requester.progressValues, [0.5, 1])
        XCTAssertEqual(progressRecorder.values, [0.5])
        XCTAssertTrue(requester.cancelledRequestIDs.isEmpty)
    }

    func testTransferMapsRequestFailureAndKeepsOnlyPartialBytes() async throws {
        let (url, fileHandle) = try makeFile()
        defer {
            try? fileHandle.close()
            try? FileManager.default.removeItem(at: url)
        }
        let requester = StubResourceDataRequester(
            chunks: [Data([1, 2, 3])],
            completionError: NSError(domain: "ResourceRequestTest", code: 1)
        )
        var exportWasRejected = false

        do {
            _ = try await PhotoResourceExporter.transfer(
                using: requester,
                to: fileHandle,
                at: url,
                networkAccessAllowed: false
            )
        } catch let error as ResourceExportError {
            exportWasRejected = error == .exportFailed
        }

        XCTAssertTrue(exportWasRejected)
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3]))
        XCTAssertEqual(requester.networkAccessAllowed, false)
    }

    func testCancellationCancelsRequestAndIgnoresLaterData() async throws {
        let (url, fileHandle) = try makeFile()
        defer {
            try? fileHandle.close()
            try? FileManager.default.removeItem(at: url)
        }
        let requestStarted = expectation(description: "request started")
        let requester = StubResourceDataRequester(
            chunks: [Data([1, 2, 3])],
            holdCompletion: true,
            requestStarted: requestStarted
        )
        let transfer = Task {
            try await PhotoResourceExporter.transfer(
                using: requester,
                to: fileHandle,
                at: url,
                networkAccessAllowed: false
            )
        }
        await fulfillment(of: [requestStarted], timeout: 2)
        transfer.cancel()
        var cancellationWasPropagated = false

        do {
            _ = try await transfer.value
        } catch is CancellationError {
            cancellationWasPropagated = true
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        requester.send(Data([4, 5]))
        try fileHandle.synchronize()

        XCTAssertTrue(cancellationWasPropagated)
        XCTAssertEqual(requester.cancelledRequestIDs, [41])
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3]))
    }

    private func makeFile() throws -> (URL, FileHandle) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ResourceExportError.exportFailed
        }
        return (url, try FileHandle(forWritingTo: url))
    }
}

private final class TransferProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Double] = []

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    func record(_ value: Double) {
        lock.lock()
        storedValues.append(value)
        lock.unlock()
    }
}

private final class StubResourceDataRequester: ResourceDataRequester, @unchecked Sendable {
    private let lock = NSLock()
    private let chunks: [Data]
    private let completionError: Error?
    private let holdCompletion: Bool
    private let requestStarted: XCTestExpectation?
    private var dataReceivedHandler: ((Data) -> Void)?
    private var completionHandler: ((Error?) -> Void)?
    private var storedNetworkAccessAllowed: Bool?
    private var storedProgressValues: [Double] = []
    private var storedCancelledRequestIDs: [PHAssetResourceDataRequestID] = []

    init(
        chunks: [Data],
        completionError: Error? = nil,
        holdCompletion: Bool = false,
        requestStarted: XCTestExpectation? = nil
    ) {
        self.chunks = chunks
        self.completionError = completionError
        self.holdCompletion = holdCompletion
        self.requestStarted = requestStarted
    }

    var networkAccessAllowed: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return storedNetworkAccessAllowed
    }

    var progressValues: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storedProgressValues
    }

    var cancelledRequestIDs: [PHAssetResourceDataRequestID] {
        lock.lock()
        defer { lock.unlock() }
        return storedCancelledRequestIDs
    }

    func requestData(
        isNetworkAccessAllowed: Bool,
        progressHandler: @escaping (Double) -> Void,
        dataReceivedHandler: @escaping (Data) -> Void,
        completionHandler: @escaping (Error?) -> Void
    ) -> PHAssetResourceDataRequestID {
        lock.lock()
        storedNetworkAccessAllowed = isNetworkAccessAllowed
        storedProgressValues = [0.5, 1]
        self.dataReceivedHandler = dataReceivedHandler
        self.completionHandler = completionHandler
        lock.unlock()
        progressHandler(0.5)
        chunks.forEach(dataReceivedHandler)
        requestStarted?.fulfill()
        if !holdCompletion { completionHandler(completionError) }
        return 41
    }

    func cancelDataRequest(_ requestID: PHAssetResourceDataRequestID) {
        lock.lock()
        storedCancelledRequestIDs.append(requestID)
        lock.unlock()
    }

    func send(_ data: Data) {
        lock.lock()
        let handler = dataReceivedHandler
        lock.unlock()
        handler?(data)
    }
}
