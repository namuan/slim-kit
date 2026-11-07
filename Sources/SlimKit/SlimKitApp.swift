import SwiftData
import SwiftUI

@main
struct SlimKitApp: App {
    init() {
        AppLogger.shared.info("Application", "Launch started; bundleID=com.slimkit.app")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: ReviewRecord.self)
    }
}
