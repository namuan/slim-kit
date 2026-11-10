import AppKit
import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query private var reviewRecords: [ReviewRecord]
    @Query var sizeRecords: [VerifiedSizeRecord]
    @Query var workflowRecords: [CompressionWorkflowRecord]
    @State var library = PhotosLibraryModel()
    @State var filter = LibraryFilter.all
    @State var selectedIDs = Set<String>()
    @State var sizeRecordsByID: [String: VerifiedSizeRecord] = [:]
    @State var visibleAssets: [MediaAsset] = []
    @State var verifiedVisibleAssetCount = 0
    @State var previewAsset: MediaAsset?
    @State var sizeTask: Task<Void, Never>?
    @State var sizeProgressMessage: String?
    @State var sizeStatusMessage: String?
    @State var showingSizeExportConfirmation = false
    @State private var capabilityCacheLogger = MediaCapabilityCacheLogger()
    @State var sortOrder = LibrarySortOrder.newest
    @AppStorage("thumbnailMinimumWidth") var thumbnailMinimumWidth = 230.0
    @State var compressionPreset = CompressionPreset.balanced
    @State var compressionResults: [CompressionQueueResult] = []
    @State var compressionProgress: CompressionQueueProgress?
    @State var compressionTask: Task<Void, Never>?
    @State var isCompressing = false
    @State var isImporting = false
    @State var importProgressMessage: String?
    @State var importStatusMessages: [String] = []
    @State var compressionStatusMessage: String?
    @State var showingCompressionConfirmation = false
    @State var showingImportConfirmation = false
    @State var showingDeletionNetworkConfirmation = false
    @State var showingDeletionConfirmation = false
    @State var pendingDeletionOperationID: String?
    @State var pendingDeletionReview: OriginalDeletionReview?
    @State var deletionNetworkAccessAllowed = false
    @State var deletionStatusMessage: String?

    var keptIDs: Set<String> {
        Set(reviewRecords.filter(\.isKept).map(\.assetID))
    }

    var body: some View {
        NavigationSplitView {
            List(LibraryFilter.allCases, selection: $filter) { item in
                Label(item.rawValue, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationTitle("SlimKit")
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } content: {
            libraryContent
                .navigationSplitViewColumnWidth(min: 500, ideal: 800)
        } detail: {
            workflowContent
                .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 520)
        }
        .frame(minWidth: 1050, minHeight: 600)
        .onChange(of: sizeRecords.count) { _, _ in
            rebuildLibraryPresentation()
            capabilityCacheLogger.recordRestorations(for: visibleAssets, records: sizeRecordsByID)
        }
        .onChange(of: library.assets.count) { _, _ in
            rebuildLibraryPresentation()
            capabilityCacheLogger.recordRestorations(for: visibleAssets, records: sizeRecordsByID)
        }
        .onChange(of: library.assetPresentationRevision) { _, _ in
            rebuildLibraryPresentation()
        }
        .onChange(of: filter) { _, _ in
            rebuildLibraryPresentation()
        }
        .onChange(of: sortOrder) { _, _ in
            rebuildLibraryPresentation()
        }
        .onChange(of: keptIDs) { _, _ in
            rebuildLibraryPresentation()
        }
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
        .onAppear {
            library.start()
            rebuildLibraryPresentation()
            restoreRetainedArtifacts()
        }
        .confirmationDialog(
            "Compress selected originals?",
            isPresented: $showingCompressionConfirmation,
            titleVisibility: .visible
        ) {
            Button("Allow iCloud Downloads and Compress") {
                startCompression(networkAccessAllowed: true)
            }
            Button("Use Local Resources Only") {
                startCompression(networkAccessAllowed: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The selected originals may be exported locally. Photos will not be changed. " +
                 "Choose whether SlimKit may download missing iCloud resources.")
        }
        .confirmationDialog(
            "Re-verify original and replacement?",
            isPresented: $showingDeletionNetworkConfirmation,
            titleVisibility: .visible
        ) {
            Button("Allow iCloud Downloads and Continue") {
                prepareOriginalDeletion(networkAccessAllowed: true)
            }
            Button("Use Local Resources Only") {
                prepareOriginalDeletion(networkAccessAllowed: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("SlimKit will freshly export and verify the original and replacement. " +
                 "This may download iCloud resources, but will not delete anything until a separate confirmation.")
        }
        .confirmationDialog(
            "Delete the original from Photos?",
            isPresented: $showingDeletionConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Original from Photos", role: .destructive) {
                deleteOriginalAfterConfirmation()
            }
            Button("Keep Original", role: .cancel) {
                pendingDeletionReview = nil
                pendingDeletionOperationID = nil
            }
        } message: {
            Text(deletionConfirmationMessage)
        }
        .confirmationDialog(
            "Import compressed results to Photos?",
            isPresented: $showingImportConfirmation,
            titleVisibility: .visible
        ) {
            Button("Import and Verify with iCloud Access") {
                importCompressedResults(networkAccessAllowed: true)
            }
            Button("Import and Verify Local Resources Only") {
                importCompressedResults(networkAccessAllowed: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This adds new Photos assets. Originals remain untouched. " +
                 "SlimKit independently checks each replacement before it can be considered safe " +
                 "for any later deletion decision.")
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
}
