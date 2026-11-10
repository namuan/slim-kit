import Foundation

struct MediaGridLayout {
    static let horizontalPadding: CGFloat = 20
    static let spacing: CGFloat = 16
    static let thumbnailSizeRange = 190.0...320.0

    let columnCount: Int
    let cardWidth: CGFloat

    var thumbnailHeight: CGFloat { cardWidth * 0.75 }

    init(availableWidth: CGFloat, preferredWidth: Double) {
        let width = max(1, availableWidth - Self.horizontalPadding * 2)
        let preferred = preferredWidth.isFinite ? preferredWidth : 230
        let range = Self.thumbnailSizeRange
        let minimum = CGFloat(min(max(preferred, range.lowerBound), range.upperBound))
        columnCount = max(1, Int((width + Self.spacing) / (minimum + Self.spacing)))
        cardWidth = max(1, (width - CGFloat(columnCount - 1) * Self.spacing) / CGFloat(columnCount))
    }
}
