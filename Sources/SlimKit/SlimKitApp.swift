import Foundation
import SwiftData
import SwiftUI

@main
struct SlimKitApp: App {
    private static var isUnitTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    init() {
        AppLogger.shared.info(
            "Application",
            "Launch started; bundleID=com.slimkit.app; unitTestHost=\(Self.isUnitTestHost)"
        )
    }

    var body: some Scene {
        WindowGroup {
            if Self.isUnitTestHost {
                EmptyView()
            } else {
                ContentView()
            }
        }
        .modelContainer(for: [ReviewRecord.self, VerifiedSizeRecord.self])
    }
}
