import SwiftUI

struct MediaBrowserGrid<Content: View>: View {
    let preferredWidth: Double
    @ViewBuilder let content: (MediaGridLayout) -> Content

    var body: some View {
        GeometryReader { geometry in
            let layout = MediaGridLayout(availableWidth: geometry.size.width, preferredWidth: preferredWidth)
            ScrollView {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(
                            .fixed(layout.cardWidth), spacing: MediaGridLayout.spacing, alignment: .top
                        ),
                        count: layout.columnCount
                    ),
                    alignment: .leading,
                    spacing: MediaGridLayout.spacing
                ) {
                    content(layout)
                }
                .padding(MediaGridLayout.horizontalPadding)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
