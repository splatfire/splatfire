import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Two buttons to pick a video: from Photos or from Files. The chosen video
/// is copied into app storage and `onImported` is called with the new file name.
///
/// - `.vertical` (default): two big full-width buttons.
/// - `.horizontal`: two compact capsule buttons side by side.
struct VideoImportButtons: View {
    /// Called on the main thread with (stored file name, original file name).
    var onImported: (_ storedFileName: String, _ originalName: String) -> Void
    var axis: Axis = .vertical

    init(axis: Axis = .vertical,
         onImported: @escaping (_ storedFileName: String, _ originalName: String) -> Void) {
        self.axis = axis
        self.onImported = onImported
    }

    @State private var photoItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var isCopying = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            if axis == .horizontal {
                HStack(spacing: Theme.spacingS) {
                    photosPicker(title: "Photos")
                    filesButton(title: "Files")
                }
            } else {
                photosPicker(title: "From Photos")
                filesButton(title: "From Files")
            }

            if isCopying {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Copying video…")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                }
                .padding(.top, 4)
            }
        }
        .disabled(isCopying)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await importFromPhotos(item) }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.movie]) { result in
            switch result {
            case .success(let url):
                Task { await importFromFiles(url) }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .alert("Couldn't import video", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Buttons

    // PhotosPicker runs outside the app, so it needs no Photos permission.
    // `.current` = give us the original file; don't convert it first
    // (converting a long video can take minutes).
    @ViewBuilder
    private func photosPicker(title: String) -> some View {
        if axis == .horizontal {
            PhotosPicker(selection: $photoItem, matching: .videos, preferredItemEncoding: .current) {
                Label(title, systemImage: "photo.on.rectangle")
            }
            .buttonStyle(ImportCapsuleButtonStyle())
        } else {
            PhotosPicker(selection: $photoItem, matching: .videos, preferredItemEncoding: .current) {
                Label(title, systemImage: "photo.on.rectangle")
            }
            .buttonStyle(.big)
        }
    }

    @ViewBuilder
    private func filesButton(title: String) -> some View {
        let button = Button {
            showFileImporter = true
        } label: {
            Label(title, systemImage: "folder")
        }
        if axis == .horizontal {
            button.buttonStyle(ImportCapsuleButtonStyle())
        } else {
            button.buttonStyle(.big)
        }
    }

    @MainActor
    private func importFromPhotos(_ item: PhotosPickerItem) async {
        isCopying = true
        defer { isCopying = false; photoItem = nil }
        do {
            // Large videos (or ones stored in iCloud) can take a while here.
            if let movie = try await item.loadTransferable(type: PickedMovie.self) {
                onImported(movie.storedFileName, movie.originalName)
            } else {
                errorMessage = "The selected item isn't a video."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func importFromFiles(_ url: URL) async {
        isCopying = true
        defer { isCopying = false }
        do {
            // Copy off the main thread so the UI doesn't freeze on big files.
            let name = try await Task.detached(priority: .userInitiated) {
                try VideoStorage.importSecurityScopedVideo(from: url)
            }.value
            onImported(name, url.lastPathComponent)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Button styles

/// Compact glass capsule used for the side-by-side import buttons.
private struct ImportCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity, minHeight: Theme.controlHeight)
            .glassSurface(Capsule(), interactive: true)
            .opacity(configuration.isPressed && !Theme.usesGlass ? 0.6 : 1)
            .contentShape(Capsule())
    }
}

/// The one main call-to-action on an empty screen: a solid accent capsule.
struct AccentCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 28)
            .frame(minHeight: 50)
            .background(Capsule().fill(Theme.accent))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}
