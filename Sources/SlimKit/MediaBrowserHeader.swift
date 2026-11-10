import SwiftUI

struct MediaBrowserHeader: View {
    let title: String
    let summary: String
    @Binding var sortOrder: LibrarySortOrder
    @Binding var thumbnailMinimumWidth: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title.weight(.semibold))
                    .lineLimit(1)
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) {
                    sortControl
                    Spacer(minLength: 16)
                    thumbnailControl
                }
                VStack(alignment: .leading, spacing: 12) {
                    sortControl
                    thumbnailControl
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var sortControl: some View {
        Picker("Sort", selection: $sortOrder) {
            ForEach(LibrarySortOrder.allCases) { order in
                Text(order.rawValue).tag(order)
            }
        }
        .frame(width: 190)
    }

    private var thumbnailControl: some View {
        HStack(spacing: 8) {
            Text("Thumbnail size")
                .font(.caption)
                .foregroundStyle(.secondary)
            Image(systemName: "square.grid.3x3")
                .accessibilityHidden(true)
            Slider(value: $thumbnailMinimumWidth, in: MediaGridLayout.thumbnailSizeRange, step: 10)
                .frame(width: 112)
                .accessibilityLabel("Thumbnail size")
                .help("Adjust thumbnail size. Columns automatically fit the library pane.")
            Image(systemName: "square.grid.2x2")
                .accessibilityHidden(true)
        }
        .foregroundStyle(.secondary)
    }
}
