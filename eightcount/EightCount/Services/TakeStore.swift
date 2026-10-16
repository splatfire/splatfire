import Foundation
import SwiftData

/// Creating and deleting recordings ("takes") in one place, so the video
/// file and the database entry always go together.
enum TakeStore {
    /// Folder-relative name for a new take video, e.g. "take-<uuid>.mov".
    static func newTakeFileName() -> String {
        "take-\(UUID().uuidString).mov"
    }

    /// Saves a finished recording (already written to
    /// `VideoStorage.url(forFileName: fileName)`) as a new take.
    @MainActor
    @discardableResult
    static func addTake(fileName: String, tutorialStart: Double, tutorialEnd: Double,
                        takeOffset: Double, recordRate: Double,
                        to project: Project, context: ModelContext) -> Take {
        let take = Take(fileName: fileName, tutorialStart: tutorialStart, tutorialEnd: tutorialEnd,
                        takeOffset: takeOffset, recordRate: recordRate)
        context.insert(take)
        take.project = project
        project.updatedAt = .now
        try? context.save()
        return take
    }

    /// Deletes a take and its video file (ask the user first!).
    @MainActor
    static func delete(_ take: Take, context: ModelContext) {
        let fileName = take.fileName
        if let project = take.project {
            let id = take.persistentModelID
            project.takes.removeAll { $0.persistentModelID == id }
        }
        context.delete(take)
        try? context.save()
        VideoStorage.deleteVideo(named: fileName)
    }

    /// Removes the video files of all takes of a project (call before
    /// deleting the project; the database rows go with the cascade).
    @MainActor
    static func deleteTakeFiles(of project: Project) {
        for take in project.takes {
            VideoStorage.deleteVideo(named: take.fileName)
        }
    }
}
