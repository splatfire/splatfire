import Foundation
import SwiftData

/// One recording of yourself, made while the tutorial played.
///
/// Timing: during recording, the tutorial started playing `takeOffset`
/// seconds into the recording, at tutorial time `tutorialStart`, at speed
/// `recordRate` (e.g. 0.5 if you practiced at half speed). `TakeTiming`
/// does the math to line the two videos up.
@Model
final class Take {
    var id: UUID
    /// File name inside `VideoStorage.directory`.
    var fileName: String
    var createdAt: Date
    /// Tutorial time (s) when the tutorial started during recording.
    var tutorialStart: Double
    /// Tutorial time (s) when recording stopped.
    var tutorialEnd: Double
    /// Seconds into the recording when the tutorial started (the countdown).
    var takeOffset: Double
    /// Tutorial speed while recording (0.25 ... 1).
    var recordRate: Double
    /// Manual fine-tuning of the sync, in seconds of the take (+ = show a
    /// later moment of your take). Set in the compare screen.
    var syncNudge: Double
    /// Encoded `AnalysisReport` (JSON), once analyzed.
    var analysisData: Data?
    /// Recorded with the tutorial hidden (memory test).
    var memoryTest: Bool = false

    var project: Project?

    init(fileName: String, tutorialStart: Double, tutorialEnd: Double,
         takeOffset: Double, recordRate: Double) {
        self.id = UUID()
        self.fileName = fileName
        self.createdAt = .now
        self.tutorialStart = tutorialStart
        self.tutorialEnd = tutorialEnd
        self.takeOffset = takeOffset
        self.recordRate = recordRate
        self.syncNudge = 0
    }

    var videoURL: URL { VideoStorage.url(forFileName: fileName) }

    var timing: TakeTiming {
        TakeTiming(tutorialStart: tutorialStart, tutorialEnd: tutorialEnd,
                   takeOffset: takeOffset, recordRate: recordRate, syncNudge: syncNudge)
    }

    /// The saved analysis, decoded. Setting it stores it as JSON.
    var analysisReport: AnalysisReport? {
        get {
            guard let analysisData else { return nil }
            return try? JSONDecoder().decode(AnalysisReport.self, from: analysisData)
        }
        set {
            analysisData = newValue.flatMap { try? JSONEncoder().encode($0) }
        }
    }
}
