import AppKit
import SwiftUI

struct PhotosAuthorizationView: View {
    let accessState: PhotosAccessState
    let errorMessage: String?
    let onConnect: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.stack")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.weight(.semibold))
            Text(description)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
            if accessState == .notDetermined {
                Button("Connect Apple Photos", action: onConnect)
                    .buttonStyle(.borderedProminent)
            } else if accessState == .denied || accessState == .restricted {
                Button("Open Privacy Settings") {
                    if let settingsURL = URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos"
                    ) {
                        NSWorkspace.shared.open(settingsURL)
                    }
                }
                .buttonStyle(.borderedProminent)
            } else if accessState == .limited {
                Button("Refresh Library", action: onRefresh)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var title: String {
        switch accessState {
        case .notDetermined: "Connect Apple Photos"
        case .authorized: "Loading Apple Photos"
        case .limited: "Limited Photos Access"
        case .denied: "Photos Access Is Off"
        case .restricted: "Photos Access Is Restricted"
        }
    }

    private var description: String {
        switch accessState {
        case .notDetermined:
            "SlimKit scans and compresses media locally. Connect Photos to browse your library."
        case .authorized:
            "SlimKit is waiting for access to your library."
        case .limited:
            "SlimKit can browse only the items you've made available to this app."
        case .denied:
            "Allow SlimKit to access Photos in macOS Privacy & Security settings. No library changes have been made."
        case .restricted:
            "This Mac restricts access to Photos. No library changes have been made."
        }
    }
}
