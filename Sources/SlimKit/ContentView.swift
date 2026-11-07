import AppKit
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
    @Query private var sizeRecords: [VerifiedSizeRecord]
    @State private var library = PhotosLibraryModel()
    @State private var filter = LibraryFilter.all
    @State private var selectedIDs = Set<String>()
    @State private var previewAsset: MediaAsset?
    @State private var sizeTask: Task<Void, Never>?
    @State private var sizeProgressMessage: String?
    @State private var sizeStatusMessage: String?
    @State private var showingSizeExportConfirmation = false
    @State private var columnCount = 5

    private var keptIDs: Set<String> {
        Set(reviewRecords.filter(\.isKept).map(\.assetID))
    }

    private var sizeRecordsByID: [String: VerifiedSizeRecord] {
        Dictionary(sizeRecords.map { ($0.assetID, $0) }, uniquingKeysWith: { _, newest in newest })
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
        .sheet(item: $previewAsset) { asset in
            MediaPreviewView(asset: asset)
                .frame(minWidth: 700, minHeight: 500)
        }
        .alert(
            "Export selected originals to verify size?",
            isPresented: $showingSizeExportConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Export and Count") {
                calculateSelectedSizes()
            }
        } message: {
            Text(
                "SlimKit will export selected originals, including iCloud downloads. " +
                    "Temporary files are removed; Photos items are unchanged."
            )
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
        let cachedSizes = sizeRecordsByID
        let verifiedCount = visibleAssets.filter { asset in
            guard let record = cachedSizes[asset.id] else { return false }
            return record.isValid(for: asset)
        }.count
        let sizeSummary = verifiedCount == 0 ? "sizes not calculated" : "\(verifiedCount) sizes verified"
        let count = "\(visibleAssets.count) items"
        if library.accessState == .limited {
            return "\(count) · limited Photos access · \(sizeSummary)"
        }
        return "\(count) · \(sizeSummary)"
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
                                sizeLabel: sizeLabel(for: asset),
                                isSelected: selectedIDs.contains(asset.id),
                                isKept: keptIDs.contains(asset.id),
                                onSelect: { toggleSelection(asset.id) },
                                onKeep: { setKept(!keptIDs.contains(asset.id), for: asset.id) },
                                onPreview: { previewAsset = asset }
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
            if let sizeProgressMessage {
                ProgressView(sizeProgressMessage)
                Button("Cancel") {
                    sizeTask?.cancel()
                }
            } else {
                if let sizeStatusMessage {
                    Text(sizeStatusMessage)
                        .foregroundStyle(.secondary)
                }
                Button("Verify Sizes") {
                    showingSizeExportConfirmation = true
                }
                Button("Clear Selection") {
                    selectedIDs.removeAll()
                    sizeStatusMessage = nil
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

}

private extension ContentView {
    var accessTitle: String {
        switch library.accessState {
        case .notDetermined: "Connect Apple Photos"
        case .authorized: "Loading Apple Photos"
        case .limited: "Limited Photos Access"
        case .denied: "Photos Access Is Off"
        case .restricted: "Photos Access Is Restricted"
        }
    }

    var accessDescription: String {
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
    func symbol(for filter: LibraryFilter) -> String {
        switch filter {
        case .all: "photo.on.rectangle.angled"
        case .photos: "photo"
        case .videos: "video"
        case .kept: "bookmark"
        }
    }

    func sizeLabel(for asset: MediaAsset) -> String {
        guard let record = sizeRecordsByID[asset.id], record.isValid(for: asset) else {
            return "Size not calculated"
        }
        return "\(ByteCountFormatter.string(fromByteCount: record.byteCount, countStyle: .file)) · verified"
    }

    func calculateSelectedSizes() {
        let selectedAssets = library.assets.filter { selectedIDs.contains($0.id) }
        guard !selectedAssets.isEmpty else { return }
        sizeStatusMessage = nil
        sizeTask = Task { @MainActor in
            var recordsByID = sizeRecordsByID
            var measuredCount = 0
            var failureCount = 0
            for (index, asset) in selectedAssets.enumerated() {
                guard !Task.isCancelled else { break }
                sizeProgressMessage = "Exporting \(index + 1) of \(selectedAssets.count)"
                do {
                    let measurement = try await PhotoResourceExporter.measure(
                        assetIdentifier: asset.id,
                        networkAccessAllowed: true
                    )
                    guard !Task.isCancelled else { break }
                    storeVerifiedSize(measurement.size, for: asset, recordsByID: &recordsByID)
                    library.applyCapabilityDecision(measurement.capabilities, for: asset.id)
                    measuredCount += 1
                } catch is CancellationError {
                    break
                } catch let error as ResourceExportError {
                    markSizeUnavailable(error, for: asset)
                    failureCount += 1
                } catch {
                    markSizeUnavailable(error, for: asset)
                    failureCount += 1
                }
            }
            if Task.isCancelled {
                AppLogger.shared.info("ResourceExport", "Selected size verification cancelled")
            } else {
                sizeStatusMessage = "\(measuredCount) verified · \(failureCount) unavailable"
            }
            sizeProgressMessage = nil
            sizeTask = nil
        }
    }

    func markSizeUnavailable(_ error: Error, for asset: MediaAsset) {
        if let resourceError = error as? ResourceExportError,
           case let .unsupported(reason) = resourceError {
            library.updateEligibility(.unsupported(reason), for: asset.id)
        } else {
            library.updateEligibility(
                .unavailable("The selected resource could not be verified."),
                for: asset.id
            )
        }
        AppLogger.shared.warning(
            "ResourceExport",
            "Selected resource not measured; error=\(error.localizedDescription)"
        )
    }

    func storeVerifiedSize(
        _ size: VerifiedResourceSize,
        for asset: MediaAsset,
        recordsByID: inout [String: VerifiedSizeRecord]
    ) {
        if let record = recordsByID[asset.id] {
            record.update(with: size)
        } else {
            let record = VerifiedSizeRecord(size: size)
            modelContext.insert(record)
            recordsByID[asset.id] = record
        }
        let eligibility: MediaEligibility = asset.kind == .photo ? .inspectImageSource : .inspectVideoSource
        library.updateEligibility(eligibility, for: asset.id)
    }

    func toggleSelection(_ id: String) {
        sizeStatusMessage = nil
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    func setKept(_ isKept: Bool, for id: String) {
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
