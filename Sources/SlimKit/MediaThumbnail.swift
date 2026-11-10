import AppKit
import SwiftUI

struct MediaThumbnail: View {
    let image: NSImage?
    let height: CGFloat
    let isVideo: Bool
    let durationText: String
    let isSelected: Bool

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(height: height)
            .overlay {
                GeometryReader { geometry in
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    } else {
                        Image(systemName: isVideo ? "video" : "photo")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isVideo {
                    Label(durationText, systemImage: "play.fill")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.7), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topTrailing) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, isSelected ? Color.accentColor : .black.opacity(0.45))
                    .padding(8)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isSelected ? Color.accentColor : .primary.opacity(0.08), lineWidth: isSelected ? 3 : 1
                    )
            }
    }
}
