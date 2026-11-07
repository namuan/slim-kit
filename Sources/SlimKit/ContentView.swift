import AppKit
import Photos
import SwiftData
import SwiftUI

private enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All Media"
    case photos = "Photos"
    case videos = "Videos"
    case kept = "Kept"

    var id: String { rawValue }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query private var reviewRecords: [ReviewRecord]
    @State private var library = PhotosLibraryModel()
    @State private var filter = LibraryFilter.all
    @State private var selectedIDs = Set<String>()
    @State private var columnCount = 5

    private var keptIDs: Set<String> {
        Set(reviewRecords.filter(\.isKept).map(\.assetID))
    }

    private var visibleAssets: [MediaAsset] {
        switch filter {
        case .all:
            library.assets
        case .photos:
            library.assets.filter { $0.kind == .photo }
        case .videos:
            library.assets.filter { $0.kind == .video }
        case .kept:
            library.assets.filter { keptIDs.contains($0.id) }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(LibraryFilter.allCases, selection: $filter) { item in
                Label(item.rawValue, systemImage: symbol(for: item))
                    .tag(item)
            }
            .navigationTitle("SlimKit")
            .listStyle(.sidebar)
            .frame(minWidth: 180)
        } detail: {
            libraryContent
        }
        .frame(minWidth: 850, minHeight: 560)
        .onChange(of: scenePhase) { _, phase in
            AppLogger.shared.info("Application", "Scene phase changed to \(phase)")
            if phase == .active {
                library.refreshAuthorization()
            }
        }
    }

    private var libraryContent: some View {
        VStack(spacing: 0) {
            header
            if library.accessState.canRead {
                mediaBrowser
            } else {
                authorizationView
            }
            if !selectedIDs.isEmpty {
                selectionBar
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    AppLogger.shared.info("PhotosScan", "User requested library refresh")
                    library.refreshAssets()
                } label: {
                    Label("Refresh Library", systemImage: "arrow.clockwise")
                }
                .disabled(library.isLoading || !library.accessState.canRead)
            }
        }
    }

    private var headerSummary: String {
        if library.isLoading {
            return "Scanning Photos · \(library.scannedAssetCount) of \(library.totalAssetCount) items"
        }
        let count = "\(visibleAssets.count) items"
        if library.accessState == .limited {
            return "\(count) · limited Photos access · sizes not calculated"
        }
        return "\(count) · sizes not calculated"
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(filter.rawValue)
                    .font(.largeTitle.weight(.semibold))
                Text(headerSummary)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Columns", selection: $columnCount) {
                Text("4 columns").tag(4)
                Text("5 columns").tag(5)
                Text("6 columns").tag(6)
                Text("7 columns").tag(7)
            }
            .frame(width: 130)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var mediaBrowser: some View {
        Group {
            if library.isLoading && library.assets.isEmpty {
                ProgressView("Loading Photos library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleAssets.isEmpty {
                ContentUnavailableView(
                    filter == .kept ? "No Kept Items" : "No Media Found",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text(
                        filter == .kept
                            ? "Use the context menu on an item to keep it here."
                            : "No accessible photos or videos match this view."
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount),
                        spacing: 12
                    ) {
                        ForEach(visibleAssets) { asset in
                            MediaCard(
                                asset: asset,
                                isSelected: selectedIDs.contains(asset.id),
                                isKept: keptIDs.contains(asset.id),
                                onSelect: { toggleSelection(asset.id) },
                                onKeep: { setKept(!keptIDs.contains(asset.id), for: asset.id) }
                            )
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private var authorizationView: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.stack")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(accessTitle)
                .font(.title2.weight(.semibold))
            Text(accessDescription)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            if let errorMessage = library.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
            if library.accessState == .notDetermined {
                Button("Connect Apple Photos") {
                    library.connect()
                }
                .buttonStyle(.borderedProminent)
            } else if library.accessState == .denied || library.accessState == .restricted {
                Button("Open Privacy Settings") {
                    if let settingsURL = URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos"
                    ) {
                        NSWorkspace.shared.open(settingsURL)
                    }
                }
                .buttonStyle(.borderedProminent)
            } else if library.accessState == .limited {
                Button("Refresh Library") {
                    library.refreshAssets()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var selectionBar: some View {
        HStack {
            Text("\(selectedIDs.count) selected")
                .fontWeight(.medium)
            Spacer()
            Text("Compression is not available yet")
                .foregroundStyle(.secondary)
            Button("Clear Selection") {
                selectedIDs.removeAll()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var accessTitle: String {
        switch library.accessState {
        case .notDetermined: "Connect Apple Photos"
        case .authorized: "Loading Apple Photos"
        case .limited: "Limited Photos Access"
        case .denied: "Photos Access Is Off"
        case .restricted: "Photos Access Is Restricted"
        }
    }

    private var accessDescription: String {
        switch library.accessState {
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

    private func symbol(for filter: LibraryFilter) -> String {
        switch filter {
        case .all: "photo.on.rectangle.angled"
        case .photos: "photo"
        case .videos: "video"
        case .kept: "bookmark"
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func setKept(_ isKept: Bool, for id: String) {
        AppLogger.shared.info("Review", "Keep state changed; kept=\(isKept)")
        let descriptor = FetchDescriptor<ReviewRecord>(predicate: #Predicate { $0.assetID == id })
        let existing = try? modelContext.fetch(descriptor).first
        if let existing {
            if isKept {
                existing.isKept = true
                existing.updatedAt = .now
            } else {
                modelContext.delete(existing)
            }
        } else if isKept {
            modelContext.insert(ReviewRecord(assetID: id, isKept: true))
        }
    }
}

private struct MediaCard: View {
    let asset: MediaAsset
    let isSelected: Bool
    let isKept: Bool
    let onSelect: () -> Void
    let onKeep: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button(action: onSelect) {
                ZStack(alignment: .topTrailing) {
                    thumbnailContent
                        .frame(height: 150)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    if asset.kind == .video {
                        Label(durationText, systemImage: "play.fill")
                            .font(.caption2.weight(.semibold))
                            .padding(6)
                            .background(.black.opacity(0.68), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(7)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(isSelected ? .white : .white, isSelected ? .blue : .black.opacity(0.45))
                        .padding(7)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button(
                    isKept ? "Remove from Kept" : "Keep for Review",
                    systemImage: isKept ? "bookmark.slash" : "bookmark",
                    action: onKeep
                )
            }
            HStack(spacing: 5) {
                Text(asset.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? "Date unknown")
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isKept {
                    Image(systemName: "bookmark.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("Size not calculated")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(eligibilitySummary)
                .font(.caption2)
                .foregroundStyle(asset.eligibility.isUnsupported ? .orange : .secondary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
        .task(id: asset.id) {
            loadThumbnail()
        }
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .scaledToFill()
        } else {
            Rectangle()
                .fill(.quaternary)
                .overlay {
                    Image(systemName: asset.kind == .video ? "video" : "photo")
                        .foregroundStyle(.secondary)
                }
        }
    }

    private var eligibilitySummary: String {
        switch asset.eligibility {
        case .pendingInspection:
            "Eligibility not inspected"
        case .inspectImageSource, .inspectVideoSource:
            "Needs source inspection"
        case let .unsupported(reason):
            "Unsupported · \(reason)"
        }
    }

    private var durationText: String {
        guard let duration = asset.duration else { return "Video" }
        let seconds = Int(duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func loadThumbnail() {
        AppLogger.shared.debug("Thumbnail", "Request started; mediaType=\(asset.kind.rawValue); networkAccess=false")
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [asset.id], options: nil)
        guard let photoAsset = result.firstObject else {
            AppLogger.shared.warning("Thumbnail", "Request skipped; asset is no longer accessible")
            return
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        PHImageManager.default().requestImage(
            for: photoAsset,
            targetSize: CGSize(width: 420, height: 300),
            contentMode: .aspectFill,
            options: options
        ) { image, info in
            if let error = info?[PHImageErrorKey] as? Error {
                AppLogger.shared.error("Thumbnail", "Request failed; error=\(error.localizedDescription)")
                return
            }
            if info?[PHImageCancelledKey] as? Bool == true {
                AppLogger.shared.info("Thumbnail", "Request cancelled")
                return
            }
            guard let image else { return }
            if info?[PHImageResultIsDegradedKey] as? Bool != true {
                AppLogger.shared.debug("Thumbnail", "Request completed; mediaType=\(asset.kind.rawValue)")
            }
            Task { @MainActor in
                thumbnail = image
            }
        }
    }
}
