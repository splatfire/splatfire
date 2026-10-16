import SwiftData
import SwiftUI

/// All recordings of yourself for one project, newest first.
/// Tap one to compare it with the tutorial; swipe to delete (after a question).
@MainActor
struct TakesListView: View {
    let project: Project
    /// Whether the practice screen shows the tutorial mirrored (the compare
    /// screen starts the same way; "Save video" copies it).
    let tutorialMirrored: Bool
    let onOpen: (Take) -> Void
    let onRecordNew: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// The take the user swiped to delete (waiting for confirmation).
    @State private var takePendingDelete: Take?
    @State private var showDeleteConfirm = false
    /// The take whose "Save video" sheet is open.
    @State private var takeToExport: ExportTarget?

    init(project: Project, tutorialMirrored: Bool = false,
         onOpen: @escaping (Take) -> Void, onRecordNew: @escaping () -> Void) {
        self.project = project
        self.tutorialMirrored = tutorialMirrored
        self.onOpen = onOpen
        self.onRecordNew = onRecordNew
    }

    /// Newest first.
    private var sortedTakes: [Take] {
        project.takes.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        NavigationStack {
            Group {
                if sortedTakes.isEmpty {
                    emptyState
                } else {
                    takeList
                }
            }
            .background(Theme.background)
            .navigationTitle("My Takes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onRecordNew()
                    } label: {
                        Label("Record", systemImage: "video.fill")
                    }
                }
            }
            .sheet(item: $takeToExport) { target in
                ExportTakeSheet(take: target.take, project: project,
                                mirrorMe: true, mirrorTutorial: tutorialMirrored)
            }
            .confirmationDialog(
                "Delete this recording?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible,
                presenting: takePendingDelete
            ) { take in
                Button("Delete", role: .destructive) {
                    TakeStore.delete(take, context: modelContext)
                    takePendingDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    takePendingDelete = nil
                }
            } message: { _ in
                Text("The video file and its analysis will be removed. This can't be undone.")
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Pieces

    private var takeList: some View {
        List {
            // `Take` has its own `id` property, so name the identity explicitly.
            ForEach(sortedTakes, id: \.persistentModelID) { take in
                Button {
                    onOpen(take)
                } label: {
                    TakeRow(take: take)
                }
                .buttonStyle(.plain)
                .listRowBackground(Theme.surface)
                .contextMenu {
                    Button {
                        takeToExport = ExportTarget(take: take)
                    } label: {
                        Label("Save to Photos", systemImage: "square.and.arrow.down")
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        takeToExport = ExportTarget(take: take)
                    } label: {
                        Label("Save to Photos", systemImage: "square.and.arrow.down")
                    }
                    .tint(Theme.accent)

                    Button(role: .destructive) {
                        takePendingDelete = take
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No recordings yet", systemImage: "video.slash")
        } description: {
            Text("Record yourself dancing along with the tutorial, then watch both side by side.")
        } actions: {
            Button {
                onRecordNew()
            } label: {
                Label("Record Yourself", systemImage: "video.fill")
            }
            .buttonStyle(.big(isOn: true))
            .frame(maxWidth: 300)
        }
    }
}

/// Wraps a take so `.sheet(item:)` has something `Identifiable`
/// (`Take` has its own `id: UUID`, which would be confusing here).
private struct ExportTarget: Identifiable {
    let id = UUID()
    let take: Take
}

// MARK: - One row

@MainActor
private struct TakeRow: View {
    let take: Take

    var body: some View {
        // A take that was just deleted can still be drawn for a moment;
        // reading a deleted model would crash, so skip it.
        if take.modelContext != nil {
            let report = take.analysisReport
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(take.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(Color.white)

                    Text("\(formatTime(take.tutorialStart)) – \(formatTime(take.tutorialEnd))")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)

                    HStack(spacing: 10) {
                        Label(SyncedPlayback.speedLabel(take.recordRate), systemImage: "speedometer")
                            .foregroundStyle(Theme.secondaryText)
                        if take.memoryTest {
                            Label("Memory test", systemImage: "eye.slash")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .font(.system(.footnote, design: .rounded))
                }

                Spacer(minLength: 8)

                if let report {
                    scoreBadge(report.overallScore)
                }

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(minHeight: Theme.tapHeight)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
    }

    private func scoreBadge(_ score: Int) -> some View {
        let color = scoreColor(score)
        return Text("\(score)")
            .font(.system(.title3, design: .rounded).weight(.heavy))
            .monospacedDigit()
            .foregroundStyle(color)
            .frame(width: 52, height: 40)
            .background(Capsule().fill(color.opacity(0.18)))
            .accessibilityLabel("Score \(score)")
    }

    private func scoreColor(_ score: Int) -> Color {
        if score >= 80 { return Color.green }
        if score >= 60 { return Color.yellow }
        return Color.orange
    }
}
