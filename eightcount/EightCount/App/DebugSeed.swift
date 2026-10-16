#if DEBUG
import Foundation
import SwiftData

/// Test-only helper, compiled into Debug builds only (never into a release
/// build) and doing nothing unless the app is launched with `-seedDemo`.
/// The automatic UI tests use it to get a ready-made demo project (with a
/// take) from the video file given in the SEED_VIDEO environment variable.
@MainActor
enum DebugSeed {
    private static var didRun = false

    static func runIfRequested(context: ModelContext) {
        guard !didRun else { return }
        didRun = true
        guard ProcessInfo.processInfo.arguments.contains("-seedDemo"),
              let path = ProcessInfo.processInfo.environment["SEED_VIDEO"] else { return }

        // Start from an empty list.
        for project in (try? context.fetch(FetchDescriptor<Project>())) ?? [] {
            context.delete(project)
        }

        let source = URL(fileURLWithPath: path)
        guard let tutorialName = try? VideoStorage.importVideo(from: source),
              let takeName = try? VideoStorage.importVideo(from: source) else { return }

        let project = Project(title: "Demo", section: "chorus", bpm: 120, offset: 0.5)
        project.videoFileName = tutorialName
        project.originalVideoName = source.lastPathComponent
        context.insert(project)

        let note = CountNote(countIndex: 0, text: "Step right, arms up on 5")
        context.insert(note)
        note.project = project

        let take = Take(fileName: takeName, tutorialStart: 1, tutorialEnd: 9,
                        takeOffset: 3, recordRate: 1)
        context.insert(take)
        take.project = project

        // A saved analysis with two sample issues, so the UI test can open
        // coach mode without needing a real dancer in the video.
        let findings = [
            AnalysisReport.Finding(bodyPart: "Left arm", message: "Lift your left arm higher",
                                   severity: 30, time: 2.5, eightCount: 0, beat: 5),
            AnalysisReport.Finding(bodyPart: "Knees", message: "Bend your knees more — get lower",
                                   severity: 20, time: 6.0, eightCount: 1, beat: 2)
        ]
        take.analysisReport = AnalysisReport(
            createdAt: .now, overallScore: 74, timingOffset: 0.12, poseCoverage: 0.9,
            segments: [
                .init(index: 0, isEightCount: true, start: 1, end: 4.5, score: 70,
                      timingOffset: 0.1, findings: [findings[0]]),
                .init(index: 1, isEightCount: true, start: 4.5, end: 8.5, score: 78,
                      timingOffset: 0.14, findings: [findings[1]])
            ],
            topFindings: findings,
            coachText: "• Lift your left arm higher on count 5.\n• Bend your knees more.",
            coachSource: "Built-in tips", tutorialMirrored: false, takeMirrored: true)

        try? context.save()
    }
}
#endif
