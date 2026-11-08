import XCTest
@testable import SlimKit

@MainActor
final class PhotosRuntimeEnvironmentTests: XCTestCase {
    func testPhotoKitMutationAdapterCannotReachPhotosFromUnitTestHost() async throws {
        let importer = PhotoKitAssetImporter()

        XCTAssertFalse(importer.canReadAndWritePhotos)
        XCTAssertFalse(importer.canDeletePhotos)
        do {
            _ = try await importer.importAsset(
                from: FileManager.default.temporaryDirectory.appendingPathComponent("missing.jpg"),
                mediaKind: .photo,
                metadata: CompressionImportMetadata(creationDate: nil, location: nil)
            )
            XCTFail("Expected Photos import to be isolated from XCTest")
        } catch {
            XCTAssertEqual(error as? PhotosImportError, .accessUnavailable)
        }
        do {
            try await importer.deleteAsset(assetID: "fixture")
            XCTFail("Expected Photos deletion to be isolated from XCTest")
        } catch {
            XCTAssertEqual(error as? PhotosImportError, .accessUnavailable)
        }
    }

    func testLibraryModelCannotReachPhotosFromUnitTestHost() {
        XCTAssertTrue(PhotosRuntimeEnvironment.isRunningTests)
        let model = PhotosLibraryModel()

        XCTAssertEqual(model.accessState, .restricted)
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.assets.isEmpty)
        model.start()
        model.connect()
        model.refreshAuthorization()
        model.refreshAssets()
        XCTAssertEqual(model.accessState, .restricted)
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.assets.isEmpty)
    }
}
