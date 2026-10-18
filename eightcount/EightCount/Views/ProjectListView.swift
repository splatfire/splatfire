import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Home screen: all projects, newest first. Create, rename, delete, import.
@MainActor
struct ProjectListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Project.updatedAt, order: .reverse) private var projects: [Project]

    @State private var path: [Project] = []
    @State private var showNewProject = false
    @State private var showImporter = false
    @State private var projectToDelete: Project?
    @State private var projectToRename: Project?
    @State private var renameTitle = ""
    @State private var renameSection = ""
    @State private var errorMessage: String?
    @AppStorage(PracticeLog.remindersKey) private var reviewReminders = false
    @State private var showAbout = false
    private var log: PracticeLog { PracticeLog.shared }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if projects.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("EightCount")
            #if DEBUG
            // Only for the automatic UI tests (does nothing in normal use).
            .onAppear { DebugSeed.runIfRequested(context: modelContext) }
            #endif
            .navigationDestination(for: Project.self) { project in
                ProjectDetailView(project: project)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Import notes", systemImage: "square.and.arrow.down")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle(isOn: reminderBinding) {
                            Label("Review reminders", systemImage: "bell")
                        }
                        Button {
                            showAbout = true
                        } label: {
                            Label("About & Privacy", systemImage: "info.circle")
                        }
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNewProject = true
                    } label: {
                        Label("New project", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showAbout) { AboutView() }
        .sheet(isPresented: $showNewProject) {
            NewProjectSheet { project in
                path.append(project)   // open the new project right away
            }
        }
        // A project file opened from AirDrop, Messages, Mail or Files
        // ("Open in EightCount" / share sheet).
        .onOpenURL { url in
            guard url.isFileURL else { return }
            do {
                let project = try ProjectArchive.importProject(from: url, into: modelContext)
                path = [project]
            } catch {
                errorMessage = error.localizedDescription
            }
            // Files handed over by other apps are copied into our Inbox folder: tidy up.
            if url.path(percentEncoded: false).contains("/Inbox/") {
                try? FileManager.default.removeItem(at: url)
            }
        }
        // Import a project file that was exported from this app.
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                do {
                    let project = try ProjectArchive.importProject(from: url, into: modelContext)
                    path.append(project)
                } catch {
                    errorMessage = error.localizedDescription
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        // Always confirm before deleting.
        .confirmationDialog(
            "Delete \"\(projectToDelete?.displayTitle ?? "")\"?",
            isPresented: Binding(
                get: { projectToDelete != nil },
                set: { if !$0 { projectToDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: projectToDelete
        ) { project in
            Button("Delete Project", role: .destructive) { delete(project) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This deletes the project, its notes, its snapshots, your recordings and its copy of the video. This can't be undone.")
        }
        // `presenting:` hands the project to the buttons, so Save still knows
        // which project it is even after the alert has started closing.
        .alert("Rename Project", isPresented: Binding(
            get: { projectToRename != nil },
            set: { if !$0 { projectToRename = nil } }
        ), presenting: projectToRename) { project in
            TextField("Title", text: $renameTitle)
            TextField("Section", text: $renameSection)
            Button("Save") { saveRename(project) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Subviews

    /// "🔥 3 days in a row" – practise today to keep it going.
    private var streakRow: some View {
        let streak = log.streak
        return HStack(spacing: 12) {
            Image(systemName: "flame.fill")
                .font(.title2)
                .foregroundStyle(streak > 0 ? Color.orange : Theme.secondaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text(streak == 1 ? "1 day of practice" : "\(streak) days in a row")
                    .font(.headline)
                Text(log.practisedToday ? "You practised today. Nice!"
                                        : (streak > 0 ? "Practise today to keep your streak." : "Practise a minute to start a streak."))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
        }
        .listRowBackground(Theme.surface)
        .accessibilityElement(children: .combine)
    }

    /// Turning reminders on asks iOS for permission first.
    private var reminderBinding: Binding<Bool> {
        Binding(
            get: { reviewReminders },
            set: { on in
                if on {
                    Task {
                        let allowed = await PracticeLog.shared.requestPermission()
                        reviewReminders = allowed
                        if !allowed {
                            errorMessage = "Notifications are off for EightCount. Turn them on in Settings → Notifications → EightCount."
                        }
                    }
                } else {
                    reviewReminders = false
                    PracticeLog.shared.cancelAllReviews()
                }
            }
        )
    }

    /// One card per project (each project is its own list section, so the
    /// system draws the rounded card, the chevron and the spacing for us).
    private var list: some View {
        List {
            if log.streak > 0 || !log.days.isEmpty {
                Section {
                    streakRow
                }
            }
            ForEach(projects) { project in
                Section {
                    NavigationLink(value: project) {
                        ProjectRow(project: project)
                    }
                    .listRowBackground(Theme.surface)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            projectToDelete = project
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            startRename(project)
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .tint(.gray)
                    }
                    .contextMenu {
                        Button {
                            startRename(project)
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            projectToDelete = project
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.spacingL) {
            Spacer()
            Image(systemName: "figure.dance")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(Theme.accent)
                .frame(width: 96, height: 96)
                .background(Circle().fill(Theme.accent.opacity(0.14)))
            VStack(spacing: Theme.spacingS) {
                Text("Learn your first dance")
                    .font(.title2.weight(.bold))
                Text("Add a tutorial video, split it into 8-counts and practice one step at a time.")
                    .font(.body)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                showNewProject = true
            } label: {
                Label("New Project", systemImage: "plus")
            }
            .buttonStyle(AccentCapsuleButtonStyle())
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    // MARK: - Actions

    private func startRename(_ project: Project) {
        renameTitle = project.title
        renameSection = project.section
        projectToRename = project
    }

    private func saveRename(_ project: Project) {
        let title = renameTitle.trimmingCharacters(in: .whitespaces)
        if !title.isEmpty { project.title = title }
        project.section = renameSection.trimmingCharacters(in: .whitespaces)
        project.updatedAt = .now
        try? modelContext.save()
        projectToRename = nil
    }

    private func delete(_ project: Project) {
        path.removeAll { $0.id == project.id }
        VideoStorage.deleteVideo(named: project.videoFileName)
        TakeStore.deleteTakeFiles(of: project)   // your recordings
        modelContext.delete(project)   // notes and snapshots are deleted too (cascade)
        try? modelContext.save()
        projectToDelete = nil
    }
}

/// One row in the project list: video picture, title, one quiet detail line.
private struct ProjectRow: View {
    let project: Project

    var body: some View {
        HStack(spacing: 14) {
            VideoThumbnail(url: project.videoURL, cornerRadius: 10)
                .frame(width: 56, height: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text(project.title)
                    .font(.headline)
                    .lineLimit(2)
                let detail = detailLine
                if !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                }
                if project.eightCountTotal > 0 && project.knownCount > 0 {
                    progress
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 72)
    }

    /// Thin bar + "5/12 learned".
    private var progress: some View {
        let total = project.eightCountTotal
        let known = min(project.knownCount, total)
        return HStack(spacing: 8) {
            ProgressView(value: Double(known), total: Double(total))
                .tint(Theme.known)
                .frame(maxWidth: 120)
            Text("\(known)/\(total) learned")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(known) of \(total) 8-counts learned")
    }

    /// "chorus · 120 BPM · 5 notes · 2 takes"
    private var detailLine: String {
        var parts: [String] = []
        if !project.section.isEmpty {
            parts.append(project.section)
        }
        if project.bpm > 0 {
            parts.append("\(Int(project.bpm.rounded())) BPM")
        }
        let noteCount = project.notes.filter { !$0.isEmpty }.count
        if noteCount > 0 {
            parts.append("\(noteCount) \(noteCount == 1 ? "note" : "notes")")
        }
        let takeCount = project.takes.count
        if takeCount > 0 {
            parts.append("\(takeCount) \(takeCount == 1 ? "take" : "takes")")
        }
        return parts.joined(separator: " · ")
    }
}
