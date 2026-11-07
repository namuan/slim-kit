import Foundation
import SwiftData

@Model
final class ReviewRecord {
    @Attribute(.unique) var assetID: String
    var isKept: Bool
    var updatedAt: Date

    init(assetID: String, isKept: Bool, updatedAt: Date = .now) {
        self.assetID = assetID
        self.isKept = isKept
        self.updatedAt = updatedAt
    }
}
