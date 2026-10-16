import Foundation
import SwiftData

/// Small helpers for creating and deleting notes and snapshots, so the
/// SwiftData details live in one place.
///
/// SwiftData rule of thumb used here: insert a new object into the context
/// first, then set its relationship (`note.project = project`). SwiftData
/// then also adds it to the other side (`project.notes`).
enum NoteStore {
    /// The note for 8-count `index`. Creates (and saves) an empty one if
    /// there is none yet.
    @MainActor
    static func note(for index: Int, in project: Project, context: ModelContext) -> CountNote {
        if let existing = project.note(for: index) {
            return existing
        }
        let note = CountNote(countIndex: index)
        context.insert(note)
        note.project = project
        try? context.save()
        return note
    }

    /// Attaches a new pose snapshot (JPEG) to 8-count `countIndex`,
    /// creating that 8-count's note if needed.
    @MainActor
    @discardableResult
    static func addSnapshot(jpegData: Data, time: Double, countIndex: Int,
                            to project: Project, context: ModelContext) -> PoseSnapshot {
        let countNote = Self.note(for: countIndex, in: project, context: context)
        let snapshot = PoseSnapshot(time: time, imageData: jpegData)
        context.insert(snapshot)
        snapshot.note = countNote
        countNote.updatedAt = .now
        project.updatedAt = .now
        try? context.save()
        return snapshot
    }

    /// Marks how well you know 8-count `index` (creates its note if needed;
    /// removes an otherwise empty note when the mark is cleared).
    @MainActor
    static func setMastery(_ mastery: Mastery, for index: Int, in project: Project, context: ModelContext) {
        let note = Self.note(for: index, in: project, context: context)
        note.mastery = mastery
        note.updatedAt = .now
        project.updatedAt = .now
        try? context.save()
        if mastery == .unmarked { deleteIfEmpty(note, context: context) }
    }

    /// Deletes one snapshot (ask the user first!).
    @MainActor
    static func delete(_ snapshot: PoseSnapshot, context: ModelContext) {
        // Take it out of its note's list first, so the screen updates right
        // away and nothing tries to show a deleted object.
        if let note = snapshot.note {
            let id = snapshot.persistentModelID
            note.snapshots.removeAll { $0.persistentModelID == id }
            note.updatedAt = .now
            note.project?.updatedAt = .now
        }
        context.delete(snapshot)
        try? context.save()
    }

    /// Deletes `note` if nothing was written and it has no snapshots,
    /// so opening and closing an 8-count doesn't leave empty notes behind.
    @MainActor
    static func deleteIfEmpty(_ note: CountNote, context: ModelContext) {
        guard note.isEmpty else { return }
        if let project = note.project {
            let id = note.persistentModelID
            project.notes.removeAll { $0.persistentModelID == id }
        }
        context.delete(note)
        try? context.save()
    }
}
