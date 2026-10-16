import Foundation

/// Result of comparing one take with the tutorial (stored in `Take.analysisData`).
/// Plain Codable value, so it can be saved as JSON.
struct AnalysisReport: Codable, Equatable, Sendable {
    /// Bump when the format changes in a way old reports can't be read.
    var version: Int = 1
    var createdAt: Date
    /// 0–100, higher = closer to the tutorial.
    var overallScore: Int
    /// Average timing difference in seconds: + = you are late, − = early.
    var timingOffset: Double
    /// Share (0–1) of sampled frames where a body was found in both videos.
    var poseCoverage: Double
    /// One entry per 8-count (or per time chunk when no BPM is set).
    var segments: [SegmentResult]
    /// The most important things to work on, most important first.
    var topFindings: [Finding]
    /// Friendly coaching text (written by Apple Intelligence when available).
    var coachText: String
    /// "Apple Intelligence" or "Built-in tips" — shown under the text.
    var coachSource: String
    /// Mirror settings used, so a re-analysis can tell if they changed.
    var tutorialMirrored: Bool
    var takeMirrored: Bool

    struct SegmentResult: Codable, Equatable, Sendable, Identifiable {
        var id: Int { index }
        /// 8-count index (0-based), or chunk index when no BPM is set.
        var index: Int
        /// True when `index` is an 8-count (BPM set), false for time chunks.
        var isEightCount: Bool
        /// Tutorial time range of this segment.
        var start: Double
        var end: Double
        var score: Int
        /// Timing difference in this segment (s): + = late, − = early.
        var timingOffset: Double
        var findings: [Finding]
    }

    struct Finding: Codable, Equatable, Sendable, Identifiable {
        var id = UUID()
        /// Body area, e.g. "Right arm", "Knees", "Timing".
        var bodyPart: String
        /// Short, concrete instruction, e.g. "Raise your right arm higher".
        var message: String
        /// How big the difference is (degrees, seconds, or a ratio), for sorting.
        var severity: Double
        /// Tutorial time where it is most visible (jump target).
        var time: Double
        /// 8-count index and beat (1–8) if known.
        var eightCount: Int?
        var beat: Int?
    }
}
