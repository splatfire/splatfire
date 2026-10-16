import Foundation
import SwiftData

/// A named part of the dance made of several 8-counts in a row, e.g.
/// "Chorus" = 8-counts 9–16. Loop it with one tap or drill it with the
/// practice coach.
@Model
final class PracticeSection {
    var id: UUID
    var name: String
    /// First 8-count (0-based).
    var startIndex: Int
    /// Last 8-count (0-based, included).
    var endIndex: Int
    var createdAt: Date
    var project: Project?

    init(name: String, startIndex: Int, endIndex: Int) {
        self.id = UUID()
        self.name = name
        self.startIndex = min(startIndex, endIndex)
        self.endIndex = max(startIndex, endIndex)
        self.createdAt = .now
    }

    /// "8-counts 9–16" (1-based, as shown on screen).
    var rangeText: String {
        startIndex == endIndex ? "8-count \(startIndex + 1)" : "8-counts \(startIndex + 1)–\(endIndex + 1)"
    }

    func contains(_ index: Int) -> Bool {
        (startIndex...endIndex).contains(index)
    }
}
