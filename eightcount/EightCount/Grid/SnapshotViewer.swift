import SwiftUI
import SwiftData
import UIKit

/// Shows one pose snapshot big, with Close and Delete.
/// Deleting always asks first. After you confirm, the viewer closes itself
/// and then calls `onDelete` — the caller does the actual delete
/// (`NoteStore.delete`).
@MainActor
struct SnapshotViewer: View {
    let snapshot: PoseSnapshot
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

    // Everything we show is copied out of the snapshot once, when the view
    // appears. That way nothing reads the snapshot again after it is deleted.
    @State private var image: UIImage?
    @State private var time: Double?
    @State private var countIndex: Int?
    @State private var confirmDelete = false

    init(snapshot: PoseSnapshot, onDelete: @escaping () -> Void) {
        self.snapshot = snapshot
        self.onDelete = onDelete
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 16) {
                // Top bar: Close + where the picture is from.
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Color.white)
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(Theme.surfaceRaised))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        if let countIndex {
                            Text("8-count \(countIndex + 1)")
                                .font(.headline)
                        }
                        if let time {
                            Text(formatTime(time))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer(minLength: 0)

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.horizontal, 8)
                        .accessibilityLabel("Pose snapshot")
                } else if time != nil {
                    // Loaded, but the picture data could not be read.
                    ContentUnavailableView("Picture unavailable", systemImage: "photo")
                } else {
                    ProgressView()
                }

                Spacer(minLength: 0)

                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete Snapshot", systemImage: "trash")
                        .foregroundStyle(Color.red)
                }
                .buttonStyle(.big)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { loadOnce() }
        .confirmationDialog(
            "Delete this snapshot?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Snapshot", role: .destructive) {
                dismiss()
                onDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The picture is removed from this 8-count. This can't be undone.")
        }
    }

    private func loadOnce() {
        guard time == nil else { return }
        countIndex = snapshot.note?.countIndex
        image = snapshot.image
        time = snapshot.time
    }
}

// MARK: - Thumbnails (used by the 8-count rows and the note editor)

/// A small rounded preview of a snapshot. Decodes and shrinks the JPEG in
/// the background and remembers the result, so scrolling stays smooth.
@MainActor
struct SnapshotThumbnailView: View {
    let snapshot: PoseSnapshot
    var width: CGFloat = 44
    var height: CGFloat = 56

    @State private var image: UIImage?

    init(snapshot: PoseSnapshot, width: CGFloat = 44, height: CGFloat = 56) {
        self.snapshot = snapshot
        self.width = width
        self.height = height
    }

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.surfaceRaised)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel("Pose snapshot")
        .task(id: snapshot.id) {
            image = await SnapshotImageCache.thumbnail(for: snapshot)
        }
    }
}

/// Remembers shrunken snapshot images by snapshot id.
enum SnapshotImageCache {
    private static let cache = NSCache<NSUUID, UIImage>()

    /// Longest side of a thumbnail, in pixels.
    static let maxPixelSize: CGFloat = 240

    @MainActor
    static func thumbnail(for snapshot: PoseSnapshot) async -> UIImage? {
        let key = snapshot.id as NSUUID
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let data = snapshot.imageData
        let maxSide = maxPixelSize
        // Decode + shrink off the main thread.
        let thumbnail = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let full = UIImage(data: data) else { return nil }
            let longest = max(full.size.width, full.size.height)
            guard longest > maxSide else { return full }
            let scale = maxSide / longest
            let size = CGSize(width: (full.size.width * scale).rounded(),
                              height: (full.size.height * scale).rounded())
            return full.preparingThumbnail(of: size) ?? full
        }.value
        if let thumbnail {
            cache.setObject(thumbnail, forKey: key)
        }
        return thumbnail
    }
}
