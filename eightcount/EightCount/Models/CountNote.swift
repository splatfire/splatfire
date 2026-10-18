import Foundation
import SwiftData

/// Notes for one 8-count. Created lazily the first time you write something
/// or take a snapshot for that 8-count.
@Model
final class CountNote {
    /// 0-based number of the 8-count (0 = first 8-count, shown as "1").
    /// Notes are tied to this number, not to a video time, so if you change
    /// the BPM or start offset the notes stay with "8-count #n".
    var countIndex: Int
    var text: String
    var feet: String
    var arms: String
    var facing: String
    /// The lyric you hear at the start of this 8-count.
    var lyric: String
    var updatedAt: Date
    /// How well you know this 8-count: see `Mastery`. Stored as a number so
    /// new levels can be added later.
    var masteryRaw: Int = 0
    /// Where everyone stands in this 8-count (JSON of `Formation`), if drawn.
    var formationData: Data?

    var project: Project?

    /// Pose pictures for this 8-count. Deleted together with the note.
    @Relationship(deleteRule: .cascade, inverse: \PoseSnapshot.note)
    var snapshots: [PoseSnapshot] = []

    init(countIndex: Int, text: String = "", feet: String = "", arms: String = "",
         facing: String = "", lyric: String = "") {
        self.countIndex = countIndex
        self.text = text
        self.feet = feet
        self.arms = arms
        self.facing = facing
        self.lyric = lyric
        self.updatedAt = .now
    }

    /// Snapshots in the order they appear in the video.
    var sortedSnapshots: [PoseSnapshot] {
        snapshots.sorted { $0.time < $1.time }
    }

    var mastery: Mastery {
        get { Mastery(rawValue: masteryRaw) ?? Mastery.unmarked }
        set { masteryRaw = newValue.rawValue }
    }

    /// True when nothing has been written, there are no snapshots, no
    /// progress mark and no formation.
    var isEmpty: Bool {
        [text, feet, arms, facing, lyric].allSatisfy {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } && snapshots.isEmpty && masteryRaw == 0 && formationData == nil
    }
}

/// How well you know an 8-count.
enum Mastery: Int, CaseIterable, Codable {
    /// Not marked yet.
    case unmarked = 0
    /// Still learning / forgot it in a memory test.
    case learning = 1
    /// Got it.
    case known = 2

    var title: String {
        switch self {
        case .unmarked: return "Not marked"
        case .learning: return "Still learning"
        case .known: return "Got it"
        }
    }

    var symbol: String {
        switch self {
        case .unmarked: return "circle"
        case .learning: return "circle.lefthalf.filled"
        case .known: return "checkmark.circle.fill"
        }
    }
}
