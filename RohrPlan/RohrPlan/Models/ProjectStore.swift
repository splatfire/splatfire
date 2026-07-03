import Foundation

/// Persistiert Projekte als einzelne JSON-Dateien im Documents-Ordner.
@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [ScanProject] = []

    private let directory: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = docs.appendingPathComponent("Projekte", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        projects = files
            .filter { $0.pathExtension == "rohrplan" }
            .compactMap { url -> ScanProject? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(ScanProject.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func project(id: UUID) -> ScanProject? {
        projects.first { $0.id == id }
    }

    func save(_ project: ScanProject) {
        var updated = project
        updated.updatedAt = Date()
        if let data = try? JSONEncoder().encode(updated) {
            try? data.write(to: fileURL(for: updated.id), options: .atomic)
        }
        if let index = projects.firstIndex(where: { $0.id == updated.id }) {
            projects[index] = updated
        } else {
            projects.insert(updated, at: 0)
        }
        projects.sort { $0.updatedAt > $1.updatedAt }
    }

    func delete(_ project: ScanProject) {
        try? FileManager.default.removeItem(at: fileURL(for: project.id))
        projects.removeAll { $0.id == project.id }
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("rohrplan")
    }
}
