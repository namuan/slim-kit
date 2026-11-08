import Foundation
import XCTest
@testable import SlimKit

extension MediaCapabilityInspectorTests {
    func testCompressionQueueExportsVerifiedResourceAndRetainsOnlyCompressedOutput() async throws {
        let testRoot = try temporaryQueueDirectory()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let fixtureURL = testRoot.appendingPathComponent("source.jpg")
        try createNoisySRGBJPEG(at: fixtureURL)
        let fixtureData = try Data(contentsOf: fixtureURL)
        let date = Date(timeIntervalSince1970: 1_000)
        let recorder = CompressionTransferRecorder()
        let size = verifiedQueueSize(assetID: "queue-photo", data: fixtureData, date: date)
        let manager = CompressionWorkspaceManager(
            rootURL: testRoot.appendingPathComponent("Jobs", isDirectory: true),
            diskSpaceProvider: QueueDiskSpaceProvider(amount: Int64(fixtureData.count) * 3)
        )
        let progressRecorder = CompressionProgressRecorder()

        let results = await CompressionJobQueue.run(
            jobs: [CompressionQueueJob(
                verifiedSize: size,
                mediaKind: .photo,
                preset: .balanced,
                networkAccessAllowed: false
            )],
            source: FixtureCompressionResourceSource(data: fixtureData, date: date, recorder: recorder),
            workspaceManager: manager,
            progress: { progressRecorder.record($0) }
        )

        guard case let .compressed(artifact)? = results.first?.result else {
            XCTFail("Expected a compressed result, got \(String(describing: results.first?.result))")
            return
        }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(artifact.assetID, "queue-photo")
        XCTAssertLessThan(artifact.outputBytes, size.byteCount)
        XCTAssertEqual(recorder.transferCount, 1)
        XCTAssertFalse(recorder.networkAccessAllowed)
        let retainedDirectory = artifact.outputURL.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.outputURL.path))
        XCTAssertEqual(manager.loadRetainedArtifacts(), [artifact])
        let handle = try FileHandle(forWritingTo: artifact.outputURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        XCTAssertTrue(manager.loadRetainedArtifacts().isEmpty)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: manager.rootURL.path),
            ["ReadyForImport"]
        )
        XCTAssertTrue(progressRecorder.phases.contains(.downloading))
        XCTAssertTrue(progressRecorder.phases.contains(.compressing))
        XCTAssertTrue(progressRecorder.phases.contains(.validating))
        XCTAssertTrue(progressRecorder.phases.contains(.completed))
        try FileManager.default.removeItem(at: retainedDirectory)
    }

    func testCompressionQueueRunsTheVideoEngineOnTheExportedMPEG4Resource() async throws {
        let testRoot = try temporaryQueueDirectory()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let fixtureURL = testRoot.appendingPathComponent("source.mp4")
        try await createNoisyVideo(at: fixtureURL)
        let fixtureData = try Data(contentsOf: fixtureURL)
        let date = Date(timeIntervalSince1970: 1_000)
        let size = verifiedQueueSize(
            assetID: "queue-video",
            data: fixtureData,
            date: date,
            uniformTypeIdentifier: "public.mpeg-4",
            mediaKind: .video
        )
        let manager = CompressionWorkspaceManager(
            rootURL: testRoot.appendingPathComponent("Jobs", isDirectory: true),
            diskSpaceProvider: QueueDiskSpaceProvider(amount: Int64(fixtureData.count) * 3)
        )
        let progressRecorder = CompressionProgressRecorder()

        let results = await CompressionJobQueue.run(
            jobs: [CompressionQueueJob(
                verifiedSize: size,
                mediaKind: .video,
                preset: .balanced,
                networkAccessAllowed: false
            )],
            source: FixtureCompressionResourceSource(
                data: fixtureData,
                date: date,
                uniformTypeIdentifier: "public.mpeg-4",
                mediaKind: .video,
                filename: "source-resource.mp4"
            ),
            workspaceManager: manager,
            progress: { progressRecorder.record($0) }
        )

        guard case let .compressed(artifact)? = results.first?.result else {
            XCTFail("Expected a compressed video, got \(String(describing: results.first?.result))")
            return
        }
        XCTAssertEqual(artifact.outputTypeIdentifier, "public.mpeg-4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.outputURL.path))
        XCTAssertEqual(manager.loadRetainedArtifacts(), [artifact])
        XCTAssertTrue(progressRecorder.phases.contains(.validating))
    }

    func testCompressionQueueProcessesBatchSeriallyAndRetainsEachArtifact() async throws {
        let testRoot = try temporaryQueueDirectory()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let fixtureURL = testRoot.appendingPathComponent("source.jpg")
        try createNoisySRGBJPEG(at: fixtureURL)
        let fixtureData = try Data(contentsOf: fixtureURL)
        let date = Date(timeIntervalSince1970: 1_000)
        let recorder = CompressionTransferRecorder()
        let manager = CompressionWorkspaceManager(
            rootURL: testRoot.appendingPathComponent("Jobs", isDirectory: true),
            diskSpaceProvider: QueueDiskSpaceProvider(amount: Int64(fixtureData.count) * 3)
        )
        let jobs = ["batch-photo-1", "batch-photo-2"].map { assetID in
            CompressionQueueJob(
                verifiedSize: verifiedQueueSize(assetID: assetID, data: fixtureData, date: date),
                mediaKind: .photo,
                preset: .balanced,
                networkAccessAllowed: false
            )
        }

        let results = await CompressionJobQueue.run(
            jobs: jobs,
            source: FixtureCompressionResourceSource(data: fixtureData, date: date, recorder: recorder),
            workspaceManager: manager
        )

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { if case .compressed = $0.result { true } else { false } })
        XCTAssertEqual(recorder.maximumConcurrentTransfers, 1)
        XCTAssertEqual(manager.loadRetainedArtifacts().count, 2)
    }

    func testCompressionQueueCleansWorkspaceWhenSourceIsUnsupported() async throws {
        let testRoot = try temporaryQueueDirectory()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let fixtureURL = testRoot.appendingPathComponent("source.png")
        try createAlphaPNG(at: fixtureURL)
        let fixtureData = try Data(contentsOf: fixtureURL)
        let date = Date(timeIntervalSince1970: 1_000)
        let size = verifiedQueueSize(
            assetID: "queue-alpha",
            data: fixtureData,
            date: date,
            uniformTypeIdentifier: "public.png"
        )
        let manager = CompressionWorkspaceManager(
            rootURL: testRoot.appendingPathComponent("Jobs", isDirectory: true),
            diskSpaceProvider: QueueDiskSpaceProvider(amount: Int64(fixtureData.count) * 3)
        )

        let results = await CompressionJobQueue.run(
            jobs: [CompressionQueueJob(
                verifiedSize: size,
                mediaKind: .photo,
                preset: .balanced,
                networkAccessAllowed: false
            )],
            source: FixtureCompressionResourceSource(
                data: fixtureData,
                date: date,
                uniformTypeIdentifier: "public.png"
            ),
            workspaceManager: manager
        )

        guard case .skipped(.unsupportedSource)? = results.first?.result else {
            XCTFail("Expected unsupported source skip, got \(String(describing: results.first?.result))")
            return
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: manager.rootURL.path), [])
    }

    func testCompressionQueueCancelsDuringTransferAndRemovesPartialWorkspace() async throws {
        let testRoot = try temporaryQueueDirectory()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let fixtureURL = testRoot.appendingPathComponent("source.jpg")
        try createSRGBJPEG(at: fixtureURL)
        let fixtureData = try Data(contentsOf: fixtureURL)
        let date = Date(timeIntervalSince1970: 1_000)
        let size = verifiedQueueSize(assetID: "queue-cancelled", data: fixtureData, date: date)
        let manager = CompressionWorkspaceManager(
            rootURL: testRoot.appendingPathComponent("Jobs", isDirectory: true),
            diskSpaceProvider: QueueDiskSpaceProvider(amount: Int64(fixtureData.count) * 3)
        )
        let taskHolder = CompressionQueueTaskHolder()
        let task = Task {
            await CompressionJobQueue.run(
                jobs: [CompressionQueueJob(
                    verifiedSize: size,
                    mediaKind: .photo,
                    preset: .balanced,
                    networkAccessAllowed: false
                )],
                source: FixtureCompressionResourceSource(
                    data: fixtureData,
                    date: date,
                    transferProgress: 0.5
                ),
                workspaceManager: manager,
                progress: { update in
                    if update.phase == .downloading, update.fractionCompleted == 0.5 {
                        taskHolder.cancel()
                    }
                }
            )
        }
        taskHolder.install(task)

        let results = await task.value

        XCTAssertEqual(results, [CompressionQueueResult(assetID: "queue-cancelled", result: .cancelled)])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: manager.rootURL.path), [])
    }

    private func temporaryQueueDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SlimKit-Compression-Queue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func verifiedQueueSize(
        assetID: String,
        data: Data,
        date: Date,
        uniformTypeIdentifier: String = "public.jpeg",
        mediaKind: MediaAsset.Kind = .photo
    ) -> VerifiedResourceSize {
        VerifiedResourceSize(
            assetID: assetID,
            byteCount: Int64(data.count),
            sourceModificationDate: date,
            resourceSelectionBasis: "\(mediaKind == .photo ? "photo" : "video")|1|\(uniformTypeIdentifier)",
            measuredAt: date
        )
    }
}

private struct FixtureCompressionResourceSource: ResourceExportSource {
    let data: Data
    let date: Date
    var uniformTypeIdentifier = "public.jpeg"
    var transferProgress: Double = 1
    var mediaKind: MediaAsset.Kind = .photo
    var filename = "source-resource.jpg"
    var recorder = CompressionTransferRecorder()
    let canReadPhotos = true

    func selectResource(assetIdentifier: String) throws -> SelectedResource {
        SelectedResource(
            sourceModificationDate: date,
            kind: mediaKind,
            basis: "\(mediaKind == .photo ? "photo" : "video")|1|\(uniformTypeIdentifier)",
            filename: filename,
            transfer: { fileHandle, _, networkAccessAllowed, progress in
                recorder.record(networkAccessAllowed: networkAccessAllowed)
                defer { recorder.finishTransfer() }
                try await Task.sleep(nanoseconds: 1_000_000)
                try fileHandle.write(contentsOf: data)
                progress.report(transferProgress)
                return Int64(data.count)
            },
            verifySource: {}
        )
    }
}

private final class CompressionTransferRecorder {
    private let lock = NSLock()
    private var count = 0
    private var networkAllowed = false
    private var activeTransfers = 0
    private var maximumActiveTransfers = 0

    var transferCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    var maximumConcurrentTransfers: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumActiveTransfers
    }

    var networkAccessAllowed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return networkAllowed
    }

    func record(networkAccessAllowed: Bool) {
        lock.lock()
        count += 1
        activeTransfers += 1
        maximumActiveTransfers = max(maximumActiveTransfers, activeTransfers)
        networkAllowed = networkAccessAllowed
        lock.unlock()
    }

    func finishTransfer() {
        lock.lock()
        activeTransfers -= 1
        lock.unlock()
    }
}

private final class CompressionProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [CompressionQueueProgress] = []

    var phases: [CompressionPhase] {
        lock.lock()
        defer { lock.unlock() }
        return updates.map(\.phase)
    }

    func record(_ update: CompressionQueueProgress) {
        lock.lock()
        updates.append(update)
        lock.unlock()
    }
}

private final class CompressionQueueTaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelTask: (() -> Void)?
    private var cancellationRequested = false

    func install(_ task: Task<[CompressionQueueResult], Never>) {
        lock.lock()
        cancelTask = { task.cancel() }
        let shouldCancel = cancellationRequested
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let cancelTask = self.cancelTask
        lock.unlock()
        cancelTask?()
    }
}

private struct QueueDiskSpaceProvider: DiskSpaceProviding {
    let amount: Int64

    func availableBytes(at directory: URL) throws -> Int64 {
        amount
    }
}
