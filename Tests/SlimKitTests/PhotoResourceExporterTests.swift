import Foundation
import XCTest
@testable import SlimKit

final class PhotoResourceExporterTests: XCTestCase {
    func testTemporaryWorkspaceRemovesPartialFileAfterCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SlimKit-Export-Test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        var cancellationWasPropagated = false

        do {
            try await ResourceExportWorkspace.withTemporaryResource(
                in: directory,
                filename: "partial-resource.bin"
            ) { resourceURL in
                try Data([1, 2, 3, 4]).write(to: resourceURL)
                throw CancellationError()
            }
        } catch {
            cancellationWasPropagated = error is CancellationError
        }

        XCTAssertTrue(cancellationWasPropagated)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testTemporaryWorkspaceRemovesFileAfterSuccessfulOperation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SlimKit-Export-Test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let byteCount = try await ResourceExportWorkspace.withTemporaryResource(
            in: directory,
            filename: "source-resource.bin"
        ) { resourceURL in
            try Data([1, 2, 3, 4]).write(to: resourceURL)
            return (try Data(contentsOf: resourceURL)).count
        }

        XCTAssertEqual(byteCount, 4)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }
}
