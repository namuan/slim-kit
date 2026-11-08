import XCTest
@testable import SlimKit

@MainActor
final class PhotosRuntimeEnvironmentTests: XCTestCase {
    func testLibraryModelCannotReachPhotosFromUnitTestHost() {
        XCTAssertTrue(PhotosRuntimeEnvironment.isRunningTests)
        let model = PhotosLibraryModel()

        XCTAssertEqual(model.accessState, .restricted)
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.assets.isEmpty)
        model.connect()
        model.refreshAuthorization()
        model.refreshAssets()
        XCTAssertEqual(model.accessState, .restricted)
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.assets.isEmpty)
    }
}
