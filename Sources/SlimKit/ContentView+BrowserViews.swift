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
            if !compressionResults.isEmpty || !workflowRecords.isEmpty {
                CompressionWorkflowPanel(
                    compressionResults: compressionResults,
                    workflowRecords: workflowRecords,
                    importStatusMessages: importStatusMessages,
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

    var selectionBar: some View {
        HStack {
            Text("\(selectedIDs.count) selected")
                .fontWeight(.medium)
            Spacer()
            if isCompressing {
                ProgressView(compressionProgressLabel)
                Button("Cancel") { compressionTask?.cancel() }
            } else if isImporting {
                ProgressView("Importing and verifying…")
            } else if let sizeProgressMessage {
                ProgressView(sizeProgressMessage)
                Button("Cancel") { sizeTask?.cancel() }
            } else {
                if let sizeStatusMessage {
                    Text(sizeStatusMessage)
                        .foregroundStyle(.secondary)
                }
                Picker("Preset", selection: $compressionPreset) {
                    ForEach(CompressionPreset.allCases, id: \.self) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .frame(width: 160)
                Button("Verify Sizes") { showingSizeExportConfirmation = true }
                Button("Compress Selected") { showingCompressionConfirmation = true }
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
