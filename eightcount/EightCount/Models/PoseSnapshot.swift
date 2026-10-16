import Foundation
import SwiftData
import UIKit

/// A still frame grabbed from the video and attached to an 8-count.
@Model
final class PoseSnapshot {
    var id: UUID
    /// Video time (seconds) the frame was taken from.
    var time: Double
    /// JPEG data. `.externalStorage` lets SwiftData keep big blobs in
    /// separate files instead of inside the database.
    @Attribute(.externalStorage) var imageData: Data
    var createdAt: Date

    var note: CountNote?

    init(time: Double, imageData: Data) {
        self.id = UUID()
        self.time = time
        self.imageData = imageData
        self.createdAt = .now
    }

    var image: UIImage? { UIImage(data: imageData) }
}
