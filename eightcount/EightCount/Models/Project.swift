import Foundation
import SwiftData

/// One song or section you are learning, e.g. "Hype Boy – chorus".
@Model
final class Project {
    var id: UUID
    var title: String
    /// Free text like "chorus", "verse 2", "dance break".
    var section: String
    /// Song tempo in beats per minute. 0 means "not set yet".
    var bpm: Double
    /// Video time (seconds) where count 1 of the first 8-count starts.
    var offset: Double
    /// File name of the copied video inside `VideoStorage.directory`.
    /// We store only the name (not a full path) because the app's folder
    /// path can change when the app is reinstalled or updated.
    var videoFileName: String?
    /// The name the video had when it was imported (just for display).
    var originalVideoName: String?
    var createdAt: Date
    var updatedAt: Date
    /// How many 8-counts the video has (remembered from the practice
    /// screen, so the project list can show progress without loading videos).
    var eightCountTotal: Int = 0

    /// Notes for each 8-count. Deleting the project deletes its notes.
    @Relationship(deleteRule: .cascade, inverse: \CountNote.project)
    var notes: [CountNote] = []

    /// Recordings of you dancing along. Deleted with the project
    /// (their video files are removed by `TakeStore` / the project list).
    @Relationship(deleteRule: .cascade, inverse: \Take.project)
    var takes: [Take] = []

    /// Named parts of the dance ("Chorus" = 8-counts 9–16).
    @Relationship(deleteRule: .cascade, inverse: \PracticeSection.project)
    var sections: [PracticeSection] = []

    init(title: String, section: String = "", bpm: Double = 0, offset: Double = 0) {
        self.id = UUID()
        self.title = title
        self.section = section
        self.bpm = bpm
        self.offset = offset
        self.createdAt = .now
        self.updatedAt = .now
    }

    /// Full URL of the project's video, or nil if no video is attached.
    var videoURL: URL? {
        guard let videoFileName else { return nil }
        return VideoStorage.url(forFileName: videoFileName)
    }

    /// "Title · section" for headers.
    var displayTitle: String {
        section.isEmpty ? title : "\(title) · \(section)"
    }

    /// Sections in the order they happen in the dance.
    var sortedSections: [PracticeSection] {
        sections.sorted { ($0.startIndex, $0.createdAt) < ($1.startIndex, $1.createdAt) }
    }

    /// How many 8-counts are marked "Got it" (only counting real 8-counts).
    var knownCount: Int {
        let total = eightCountTotal
        return notes.filter { $0.mastery == .known && (total == 0 || $0.countIndex < total) }.count
    }

    /// The note for 8-count `index`, if one has been written.
    func note(for index: Int) -> CountNote? {
        notes.first { $0.countIndex == index }
    }
}
