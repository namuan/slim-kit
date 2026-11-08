import SwiftUI

extension ContentView {
    var libraryContent: some View {
        VStack(spacing: 0) {
            header
            if library.accessState.canRead {
                mediaBrowser
            } else {
                PhotosAuthorizationView(
                    accessState: library.accessState,
                    errorMessage: library.errorMessage,
                    onConnect: library.connect,
                    onRefresh: library.refreshAssets
                )
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

    var workflowContent: some View {
        VStack(spacing: 0) {
            selectionActionsPanel
            if isCompressing || isImporting || sizeProgressMessage != nil || sizeStatusMessage != nil {
                Divider()
                actionProgressPanel
            }
            Divider()
            if !compressionResults.isEmpty || !workflowRecords.isEmpty {
                CompressionWorkflowPanel(
                    compressionResults: compressionResults,
                    workflowRecords: workflowRecords,
                    importStatusMessages: importStatusMessages,
                    isImporting: isImporting,
                    compressionStatusMessage: compressionStatusMessage,
                    deletionStatusMessage: deletionStatusMessage,
                    onImport: { showingImportConfirmation = true },
                    onReviewDeletion: { operationID in
                        pendingDeletionOperationID = operationID
                        showingDeletionNetworkConfirmation = true
                    },
                    onRetryVerification: retryReplacementVerification,
                    onRecoverDeletion: recoverInterruptedDeletion
                )
            } else {
                ContentUnavailableView(
                    "No Compression Activity",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Compression results and workflow messages will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Activity")
    }

    var selectionActionsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Selection & Actions")
                    .font(.headline)
                Spacer()
                Text("\(selectedIDs.count) selected")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if selectedIDs.isEmpty {
                Text("Select media in the library to enable these actions.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Picker("Preset", selection: $compressionPreset) {
                ForEach(CompressionPreset.allCases, id: \.self) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .disabled(isActionInProgress)
            Button {
                showingCompressionConfirmation = true
            } label: {
                Label("Compress Selected", systemImage: "arrow.down.right.and.arrow.up.left")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedIDs.isEmpty || isActionInProgress)
            Button {
                showingSizeExportConfirmation = true
            } label: {
                Label("Verify Sizes", systemImage: "checkmark.magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(selectedIDs.isEmpty || isActionInProgress)
            if !selectedIDs.isEmpty {
                Button("Clear Selection", systemImage: "xmark.circle") {
                    selectedIDs.removeAll()
                    sizeStatusMessage = nil
                }
                .buttonStyle(.plain)
                .disabled(isActionInProgress)
            }
        }
        .padding(16)
    }

    var actionProgressPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Current Action")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if isCompressing {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(compressionProgressLabel)
                            .font(.callout)
                        if let fraction = compressionProgress?.fractionCompleted {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Cancel") { compressionTask?.cancel() }
                }
            } else if isImporting {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(importProgressMessage ?? "Importing and verifying replacements…")
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let sizeProgressMessage {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(sizeProgressMessage)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Cancel") { sizeTask?.cancel() }
                }
            } else if let sizeStatusMessage {
                Label(sizeStatusMessage, systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35))
    }

    var isActionInProgress: Bool {
        isCompressing || isImporting || sizeProgressMessage != nil
    }

    func rebuildLibraryPresentation() {
        let records: [String: VerifiedSizeRecord] = Dictionary(
            sizeRecords.map { ($0.assetID, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        sizeRecordsByID = records
        let assetsToSort: [MediaAsset]
        switch filter {
        case .all:
            assetsToSort = library.assets
        case .photos:
            assetsToSort = library.assets.filter { $0.kind == .photo }
        case .videos:
            assetsToSort = library.assets.filter { $0.kind == .video }
        case .kept:
            let kept = keptIDs
            assetsToSort = library.assets.filter { kept.contains($0.id) }
        }
        visibleAssets = MediaAssetSorter.sorted(assetsToSort, by: sortOrder, sizeRecords: records)
        verifiedVisibleAssetCount = visibleAssets.reduce(into: 0) { count, asset in
            if let record = records[asset.id], record.isValid(for: asset) {
                count += 1
            }
        }
    }

    var headerSummary: String {
        if library.isLoading {
            return "Scanning Photos · \(library.scannedAssetCount) of \(library.totalAssetCount) items"
        }
        let sizeSummary = verifiedVisibleAssetCount == 0
            ? "sizes not calculated"
            : "\(verifiedVisibleAssetCount) sizes verified"
        let count = "\(visibleAssets.count) items"
        if library.accessState == .limited {
            return "\(count) · limited Photos access · \(sizeSummary)"
        }
        return "\(count) · \(sizeSummary)"
    }

    var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(filter.rawValue)
                    .font(.largeTitle.weight(.semibold))
                Text(headerSummary)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Sort", selection: $sortOrder) {
                ForEach(LibrarySortOrder.allCases) { order in
                    Text(order.rawValue).tag(order)
                }
            }
            .frame(width: 150)
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

    var mediaBrowser: some View {
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
                                asset: MediaCapabilityCachePresentation.asset(
                                    for: asset,
                                    record: sizeRecordsByID[asset.id]
                                ),
                                sizeLabel: MediaSizePresentation.label(
                                    for: asset,
                                    record: sizeRecordsByID[asset.id]
                                ),
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

}
