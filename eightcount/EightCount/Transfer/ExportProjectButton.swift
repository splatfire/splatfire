import SwiftUI
import SwiftData

/// Toolbar button that saves the project's notes and snapshots (not the
/// video) into a file and opens the share sheet for it.
struct ExportProjectButton: View {
    let project: Project

    /// The exported file while the share sheet is showing.
    @State private var exported: ExportedFile?
    @State private var errorMessage: String?

    init(project: Project) {
        self.project = project
    }

    var body: some View {
        Button {
            export()
        } label: {
            Label("Export notes", systemImage: "square.and.arrow.up")
        }
        .accessibilityLabel("Export notes")
        .accessibilityHint("Shares this project's notes and snapshots as a file. The video is not included.")
        .sheet(item: $exported) { file in
            ShareSheet(items: [file.url]) {
                exported = nil
            }
            .presentationDetents([.medium, .large])
            .ignoresSafeArea()
        }
        .alert("Couldn't export", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// Builds the file on the main actor (SwiftData objects must stay on the
    /// thread that owns them). It only takes a moment.
    @MainActor private func export() {
        do {
            let url = try ProjectArchive.exportFile(for: project)
            exported = ExportedFile(url: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// `.sheet(item:)` needs an Identifiable value, and URL isn't one.
private struct ExportedFile: Identifiable {
    let id = UUID()
    let url: URL
}
