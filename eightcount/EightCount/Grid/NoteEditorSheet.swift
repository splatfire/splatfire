import SwiftUI
import SwiftData

/// Sheet to write notes for one 8-count: the moves, feet, arms, facing,
/// the lyric you hear, and the pose snapshots taken in it.
@MainActor
struct NoteEditorSheet: View {
    let project: Project
    let countIndex: Int
    let grid: CountGrid

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// The note being edited (found or created when the sheet appears).
    @State private var note: CountNote?
    /// What the note looked like when the sheet opened, to tell if anything changed.
    @State private var originalFingerprint = ""
    @State private var viewingSnapshot: PoseSnapshot?
    @State private var snapshotToDelete: PoseSnapshot?

    init(project: Project, countIndex: Int, grid: CountGrid) {
        self.project = project
        self.countIndex = countIndex
        self.grid = grid
    }

    var body: some View {
        NavigationStack {
            Group {
                if let note {
                    NoteEditorForm(
                        note: note,
                        onOpenSnapshot: { viewingSnapshot = $0 },
                        onDeleteSnapshot: { snapshotToDelete = $0 }
                    )
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Theme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(title)
                            .font(.headline)
                        if let timeRange {
                            Text(timeRange)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.headline)
                }
            }
        }
        .onAppear { loadNote() }
        .onDisappear { finish() }
        // A normal sheet (not full-screen), so this editor stays "on screen"
        // underneath and its onDisappear doesn't run early.
        .sheet(item: $viewingSnapshot) { snapshot in
            SnapshotViewer(snapshot: snapshot) {
                deleteSnapshot(snapshot)
            }
        }
        // Always confirm before deleting a snapshot.
        .confirmationDialog(
            "Delete this snapshot?",
            isPresented: Binding(
                get: { snapshotToDelete != nil },
                set: { if !$0 { snapshotToDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: snapshotToDelete
        ) { snapshot in
            Button("Delete Snapshot", role: .destructive) { deleteSnapshot(snapshot) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The picture is removed from this 8-count. This can't be undone.")
        }
    }

    // MARK: - Text

    private var title: String { "8-count \(countIndex + 1)" }

    /// "0:03.20 – 0:07.20", or nil without a tempo.
    private var timeRange: String? {
        guard grid.isValid else { return nil }
        return "\(formatTime(grid.start(of: countIndex))) – \(formatTime(grid.end(of: countIndex)))"
    }

    // MARK: - Actions

    private func loadNote() {
        guard note == nil else { return }
        let found = NoteStore.note(for: countIndex, in: project, context: modelContext)
        originalFingerprint = Self.fingerprint(of: found)
        note = found
    }

    /// Runs when the sheet closes: stamp the change time, and remove the
    /// note again if it is still empty.
    private func finish() {
        guard let current = note else { return }
        if Self.fingerprint(of: current) != originalFingerprint {
            current.updatedAt = .now
            project.updatedAt = .now
        }
        if current.isEmpty {
            // Stop showing it before deleting it.
            note = nil
            NoteStore.deleteIfEmpty(current, context: modelContext)
        }
        try? modelContext.save()
    }

    private func deleteSnapshot(_ snapshot: PoseSnapshot) {
        if viewingSnapshot?.persistentModelID == snapshot.persistentModelID {
            viewingSnapshot = nil
        }
        snapshotToDelete = nil
        NoteStore.delete(snapshot, context: modelContext)
    }

    /// A simple summary of the note's content, to detect edits.
    private static func fingerprint(of note: CountNote) -> String {
        [note.text, note.feet, note.arms, note.facing, note.lyric].joined(separator: "\u{1F}")
            + "|\(note.snapshots.count)"
    }
}

/// The actual form. Separate view so it can use `@Bindable` on a
/// non-optional note.
@MainActor
private struct NoteEditorForm: View {
    @Bindable var note: CountNote
    let onOpenSnapshot: (PoseSnapshot) -> Void
    let onDeleteSnapshot: (PoseSnapshot) -> Void

    var body: some View {
        Form {
            Section {
                TextField("What's the move? e.g. step R, body roll, hit on 7",
                          text: $note.text, axis: .vertical)
                    .lineLimit(3...8)
                    .font(.title3)
                    .padding(.vertical, 4)
            } header: {
                Text("Moves")
            }
            .listRowBackground(Theme.surface)

            Section {
                detailField("Feet", icon: "shoeprints.fill",
                            prompt: "e.g. step R, together, wide stance", text: $note.feet)
                detailField("Arms", icon: "figure.arms.open",
                            prompt: "e.g. arms cross, punch up on 5", text: $note.arms)
                detailField("Facing direction", icon: "location.north.line.fill",
                            prompt: "e.g. front, turn to the left on 8", text: $note.facing)
                detailField("Lyric cue (start of this 8-count)", icon: "music.note",
                            prompt: "The words you hear on count 1", text: $note.lyric)
            } header: {
                Text("Details")
            }
            .listRowBackground(Theme.surface)

            Section {
                snapshotsContent
            } header: {
                Text("Snapshots")
            } footer: {
                if !note.snapshots.isEmpty {
                    Text("Tap a picture to see it big. Touch and hold to delete it.")
                }
            }
            .listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .scrollDismissesKeyboard(.interactively)
    }

    private func detailField(_ title: String, icon: String, prompt: String,
                             text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
            TextField(prompt, text: text, axis: .vertical)
                .lineLimit(1...4)
                .font(.body)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var snapshotsContent: some View {
        let snapshots = note.sortedSnapshots
        if snapshots.isEmpty {
            Text("No snapshots yet. While watching, pause on a pose and tap the camera button to save it to this 8-count.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .padding(.vertical, 4)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(snapshots) { snapshot in
                        // .plain style: each button reacts on its own
                        // (in a Form, default-style buttons fire as one row).
                        Button {
                            onOpenSnapshot(snapshot)
                        } label: {
                            VStack(spacing: 4) {
                                SnapshotThumbnailView(snapshot: snapshot, width: 90, height: 120)
                                Text(formatTime(snapshot.time))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                onDeleteSnapshot(snapshot)
                            } label: {
                                Label("Delete Snapshot", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }
}
