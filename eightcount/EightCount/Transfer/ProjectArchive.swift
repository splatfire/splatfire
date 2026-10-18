import Foundation
import SwiftData

/// Saves a project's notes and pose snapshots (NOT the video) into one file,
/// and reads such a file back in as a new project. Use it to make a backup or
/// to send your notes to someone in your dance group.
///
/// File format: iOS has no built-in zip API, so the file is a single JSON
/// document. Snapshot JPEGs are stored inside it as base64 text
/// (`JSONEncoder` does that automatically for `Data`).
///
/// Design choice: the file is plain `.json` (named "….eightcount.json"), not
/// a custom file type. That way we don't need to declare our own UTType, and
/// the Files app / AirDrop / Messages all handle it fine. Info.plist offers
/// the app for JSON files (as an "alternate", never the default), so a shared
/// file can be opened straight into EightCount (`onOpenURL` in the list).
enum ProjectArchive {

    // MARK: - File format (plain value types, separate from the @Model classes)

    /// The whole export file.
    struct ExportFile: Codable {
        var format: String = ProjectArchive.formatName
        var version: Int = ProjectArchive.currentVersion
        var exportedAt: Date
        /// App version that wrote the file, e.g. "1.0" (just for information).
        var appVersion: String?
        var title: String
        var section: String
        var bpm: Double
        var offset: Double
        /// Name of the video the notes were made for, so the receiver knows
        /// which video to add.
        var originalVideoName: String?
        var notes: [ExportNote]
        /// Named sections. Optional: older files don't have them.
        var sections: [ExportSection]? = nil
    }

    /// One named section ("Chorus" = 8-counts 9–16, 0-based in the file).
    struct ExportSection: Codable {
        var name: String
        var startIndex: Int
        var endIndex: Int
    }

    /// Notes for one 8-count.
    struct ExportNote: Codable {
        var countIndex: Int
        var text: String
        var feet: String
        var arms: String
        var facing: String
        var lyric: String
        var snapshots: [ExportSnapshot]
        /// Progress mark (`Mastery` raw value). Optional: older files don't have it.
        var mastery: Int? = nil
        /// Formation (JSON of `Formation`). Optional: older files don't have it.
        var formation: Data? = nil
    }

    /// One pose picture.
    struct ExportSnapshot: Codable {
        var time: Double
        var createdAt: Date
        /// JPEG bytes. Written as base64 text in the JSON.
        var jpeg: Data
    }

    /// Just the first two fields. We read these first so we can show a
    /// friendly message for the wrong kind of file or a newer version,
    /// before trying to read everything else.
    private struct Header: Decodable {
        var format: String?
        var version: Int?
    }

    static let formatName = "eightcount.project"
    static let currentVersion = 1
    /// Files bigger than this are surely not ours (or broken). 300 MB.
    private static let maxImportSize = 300 * 1024 * 1024

    // MARK: - Errors

    enum ArchiveError: LocalizedError {
        case notAProjectFile
        case newerVersion
        case unreadable
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .notAProjectFile:
                return "This isn't an EightCount project file."
            case .newerVersion:
                return "This file was made with a newer version of EightCount. Please update the app to open it."
            case .unreadable:
                return "This EightCount file couldn't be read. It may be damaged or incomplete."
            case .tooLarge:
                return "This file is too large to be an EightCount project file."
            }
        }
    }

    // MARK: - Export

    /// Writes the export file into a fresh temp folder and returns its URL.
    /// File name: "<title> - <section>.eightcount.json".
    @MainActor static func exportFile(for project: Project) throws -> URL {
        // Turn the SwiftData objects into plain values.
        let notes: [ExportNote] = project.notes
            .filter { !$0.isEmpty }                     // skip empty 8-counts
            .sorted { $0.countIndex < $1.countIndex }
            .map { note in
                ExportNote(
                    countIndex: note.countIndex,
                    text: note.text,
                    feet: note.feet,
                    arms: note.arms,
                    facing: note.facing,
                    lyric: note.lyric,
                    snapshots: note.sortedSnapshots.map { snap in
                        ExportSnapshot(time: finiteOrZero(snap.time),
                                       createdAt: snap.createdAt,
                                       jpeg: snap.imageData)
                    },
                    mastery: note.masteryRaw == 0 ? nil : note.masteryRaw,
                    formation: note.formationData
                )
            }

        let file = ExportFile(
            exportedAt: .now,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            title: project.title,
            section: project.section,
            bpm: finiteOrZero(project.bpm),
            offset: finiteOrZero(project.offset),
            originalVideoName: project.originalVideoName,
            notes: notes,
            sections: project.sortedSections.map {
                ExportSection(name: $0.name, startIndex: $0.startIndex, endIndex: $0.endIndex)
            }
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)

        // Remove folders left over from earlier exports (the system would
        // clean them up eventually, but there's no reason to wait).
        removeOldExportFolders()

        // A new folder for every export, so the file itself can keep a clean,
        // readable name (two exports of the same project don't clash).
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName(for: project), isDirectory: false)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// "<title> - <section>.eightcount.json", safe to use as a file name.
    static func fileName(for project: Project) -> String {
        let title = project.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let section = project.section.trimmingCharacters(in: .whitespacesAndNewlines)
        var base = section.isEmpty ? title : "\(title) - \(section)"

        // Replace characters that aren't allowed in file names.
        let illegal: Set<Character> = ["/", "\\", ":", "?", "*", "\"", "<", ">", "|"]
        let cleaned: [Character] = base.map { character in
            (illegal.contains(character) || character.isNewline) ? "-" : character
        }
        base = String(cleaned)

        // A leading "." would make a hidden file.
        while base.hasPrefix(".") { base.removeFirst() }
        // Very long names can fail on some file systems.
        if base.count > 100 { base = String(base.prefix(100)) }
        base = base.trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = "EightCount project" }

        return base + ".eightcount.json"
    }

    /// JSON can't store "not a number" or infinity, so use 0 instead.
    private static func finiteOrZero(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }

    private static func removeOldExportFolders() {
        let fileManager = FileManager.default
        let temp = fileManager.temporaryDirectory
        guard let items = try? fileManager.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil) else {
            return
        }
        for item in items where item.lastPathComponent.hasPrefix("Export-") {
            try? fileManager.removeItem(at: item)
        }
    }

    // MARK: - Import

    /// Reads an export file, creates a NEW project with its notes and
    /// snapshots in `context`, saves, and returns it. The new project has no
    /// video; the user can add one later.
    @MainActor static func importProject(from url: URL, into context: ModelContext) throws -> Project {
        // Files picked in the Files app are "security scoped": ask for access
        // before reading, and give it back when done.
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxImportSize {
            throw ArchiveError.tooLarge
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ArchiveError.unreadable
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // 1. Is this our kind of file, and can this app version read it?
        guard let header = try? decoder.decode(Header.self, from: data),
              header.format == formatName else {
            throw ArchiveError.notAProjectFile
        }
        if let version = header.version, version > currentVersion {
            throw ArchiveError.newerVersion
        }

        // 2. Read everything.
        let file: ExportFile
        do {
            file = try decoder.decode(ExportFile.self, from: data)
        } catch {
            throw ArchiveError.unreadable
        }

        // 3. Pick a title. If the same project is already here, mark the copy
        //    as imported so you can tell them apart. (We fetch all projects and
        //    compare in Swift — simple, and there are only a few projects.)
        let title = file.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let section = file.section.trimmingCharacters(in: .whitespacesAndNewlines)
        var newTitle = title.isEmpty ? "Imported project" : title
        let existing = try context.fetch(FetchDescriptor<Project>())
        if existing.contains(where: { $0.title == newTitle && $0.section == section }) {
            newTitle += " (imported)"
        }

        // 4. Create the SwiftData objects. Insert each object into the
        //    context first, then connect it to its parent.
        let project = Project(title: newTitle, section: section,
                              bpm: max(0, file.bpm), offset: file.offset)
        project.originalVideoName = file.originalVideoName
        project.createdAt = .now
        project.updatedAt = .now   // newest, so it shows at the top of the list
        context.insert(project)

        var usedIndexes = Set<Int>()
        for exportNote in file.notes.sorted(by: { $0.countIndex < $1.countIndex }) {
            // Only one note per 8-count; ignore broken or duplicate entries.
            guard exportNote.countIndex >= 0,
                  usedIndexes.insert(exportNote.countIndex).inserted else { continue }

            let note = CountNote(countIndex: exportNote.countIndex,
                                 text: exportNote.text,
                                 feet: exportNote.feet,
                                 arms: exportNote.arms,
                                 facing: exportNote.facing,
                                 lyric: exportNote.lyric)
            note.masteryRaw = exportNote.mastery ?? 0
            note.formationData = exportNote.formation
            context.insert(note)
            note.project = project

            for exportSnap in exportNote.snapshots.sorted(by: { $0.time < $1.time }) {
                guard !exportSnap.jpeg.isEmpty else { continue }   // skip empty pictures
                let snap = PoseSnapshot(time: exportSnap.time, imageData: exportSnap.jpeg)
                snap.createdAt = exportSnap.createdAt
                context.insert(snap)
                snap.note = note
            }
        }

        for exportSection in file.sections ?? [] where exportSection.startIndex >= 0 && exportSection.endIndex >= 0 {
            let section = PracticeSection(name: exportSection.name,
                                          startIndex: exportSection.startIndex,
                                          endIndex: exportSection.endIndex)
            context.insert(section)
            section.project = project
        }

        do {
            try context.save()
        } catch {
            // Don't leave a half-imported project behind.
            context.delete(project)   // notes and snapshots go with it (cascade)
            throw error
        }
        return project
    }
}
