import Foundation

/// Keeps imported videos in the app's own folder
/// (Application Support/Videos), so they stay available even if you delete
/// the original from Photos or Files.
enum VideoStorage {
    /// Folder that holds all copied videos.
    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Videos", directoryHint: .isDirectory)
    }

    static func url(forFileName name: String) -> URL {
        directory.appending(path: name, directoryHint: .notDirectory)
    }

    /// Copies the video at `source` into app storage under a new unique name.
    /// - Returns: the new file name (store this in `Project.videoFileName`).
    static func importVideo(from source: URL) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased()
        let name = "\(UUID().uuidString).\(ext)"
        try FileManager.default.copyItem(at: source, to: url(forFileName: name))
        return name
    }

    /// Copies a file the user picked in the Files app. Those URLs are
    /// "security scoped": we must ask for access before reading them.
    static func importSecurityScopedVideo(from source: URL) throws -> String {
        let didAccess = source.startAccessingSecurityScopedResource()
        defer { if didAccess { source.stopAccessingSecurityScopedResource() } }
        return try importVideo(from: source)
    }

    /// Removes a stored video. Missing files are ignored.
    static func deleteVideo(named name: String?) {
        guard let name else { return }
        try? FileManager.default.removeItem(at: url(forFileName: name))
    }
}
