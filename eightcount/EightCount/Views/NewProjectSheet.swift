import SwiftUI
import SwiftData

/// Sheet for creating a project: title, section and (optionally) a video.
@MainActor
struct NewProjectSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// Called with the new project so the list can open it.
    var onCreated: (Project) -> Void = { _ in }

    @State private var title = ""
    @State private var section = ""
    @State private var videoFileName: String?
    @State private var originalVideoName: String?
    /// True while the person is choosing a replacement for the picked video.
    @State private var isChangingVideo = false
    @FocusState private var titleFocused: Bool
    @FocusState private var sectionFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacingL) {
                    songCard
                    videoSection
                }
                .padding(.horizontal, 16)
                .padding(.top, Theme.spacingS)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.background)
            .navigationTitle("New Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        // Don't leave an orphaned video copy behind.
                        VideoStorage.deleteVideo(named: videoFileName)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .bold()
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { titleFocused = true }
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.background)
        .interactiveDismissDisabled(videoFileName != nil)
    }

    // MARK: - Song card

    private var songCard: some View {
        VStack(spacing: 0) {
            TextField("Title (e.g. Hype Boy)", text: $title)
                .font(.title2.weight(.semibold))
                .textFieldStyle(.plain)
                .focused($titleFocused)
                .submitLabel(.next)
                .onSubmit { sectionFocused = true }
                .frame(minHeight: 44)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .padding(.leading, 16)

            TextField("Section (e.g. chorus)", text: $section)
                .font(.body)
                .textFieldStyle(.plain)
                .focused($sectionFocused)
                .submitLabel(.done)
                .frame(minHeight: 44)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
        }
        .card(padding: 0)
    }

    // MARK: - Video

    private var videoSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            Text("Video")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
                .textCase(.uppercase)
                .padding(.horizontal, 4)

            Group {
                if videoFileName != nil && !isChangingVideo {
                    pickedVideoCard
                } else {
                    addVideoTile
                }
            }
            .animation(.easeInOut(duration: 0.2), value: videoFileName)
            .animation(.easeInOut(duration: 0.2), value: isChangingVideo)

            Text("The video is copied into the app, so it stays even if you delete it from Photos. You can also add it later.")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .padding(.top, 2)
        }
    }

    /// Dashed tile with the two import buttons.
    private var addVideoTile: some View {
        VStack(spacing: Theme.spacingM) {
            Image(systemName: "video.badge.plus")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Theme.accent)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Theme.accent.opacity(0.14)))

            VStack(spacing: 2) {
                Text("Add the tutorial video")
                    .font(.headline)
                Text("Optional")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }

            VideoImportButtons(axis: .horizontal) { stored, original in
                // Picking a second video replaces the first one.
                VideoStorage.deleteVideo(named: videoFileName)
                videoFileName = stored
                originalVideoName = original
                isChangingVideo = false
            }

            if isChangingVideo {
                Button("Keep current video") { isChangingVideo = false }
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .frame(minHeight: 44)
            }
        }
        .padding(Theme.spacingL)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
        )
    }

    /// First frame, file name and a "Change" button.
    private var pickedVideoCard: some View {
        HStack(spacing: Theme.spacingM) {
            VideoThumbnail(url: videoFileName.map { VideoStorage.url(forFileName: $0) },
                           cornerRadius: 12)
                .frame(width: 96, height: 128)

            VStack(alignment: .leading, spacing: Theme.spacingS) {
                Label("Video added", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.green)
                Text(originalVideoName ?? "Video")
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Button {
                    isChangingVideo = true
                } label: {
                    Text("Change")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18)
                        .frame(minHeight: Theme.controlHeight)
                        .glassSurface(Capsule(), interactive: true)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .card()
    }

    // MARK: - Actions

    private func create() {
        let project = Project(
            title: title.trimmingCharacters(in: .whitespaces),
            section: section.trimmingCharacters(in: .whitespaces)
        )
        project.videoFileName = videoFileName
        project.originalVideoName = originalVideoName
        modelContext.insert(project)
        try? modelContext.save()
        dismiss()
        onCreated(project)
    }
}
