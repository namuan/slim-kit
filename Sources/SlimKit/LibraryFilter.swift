import SwiftUI

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All Media"
    case photos = "Photos"
    case videos = "Videos"
    case kept = "Kept"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .all: "photo.on.rectangle.angled"
        case .photos: "photo"
        case .videos: "video"
        case .kept: "bookmark"
        }
    }
}
