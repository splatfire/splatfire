import SwiftUI
import AVFoundation
import UIKit

/// A small rounded picture of a video's first frame.
/// The frame is grabbed in the background and remembered, so scrolling a
/// list of projects stays smooth. Shows a quiet placeholder until then (and
/// when there is no video). Fills whatever size the parent gives it.
@MainActor
struct VideoThumbnail: View {
    let url: URL?
    var cornerRadius: CGFloat = 10

    @State private var image: UIImage?

    init(url: URL?, cornerRadius: CGFloat = 10) {
        self.url = url
        self.cornerRadius = cornerRadius
        // If we already have the picture, show it on the very first frame.
        _image = State(initialValue: url.flatMap { VideoThumbnailCache.cached(for: $0) })
    }

    var body: some View {
        Rectangle()
            .fill(Theme.surfaceRaised)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: url == nil ? "video.slash" : "film")
                        .font(.title3)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
            .accessibilityHidden(true)
            .task(id: url) {
                guard let url else {
                    image = nil
                    return
                }
                image = await VideoThumbnailCache.thumbnail(for: url)
            }
    }
}

/// Remembers first-frame pictures by file path.
enum VideoThumbnailCache {
    private static let cache = NSCache<NSString, UIImage>()

    /// Longest side of a thumbnail, in pixels.
    static let maxPixelSize: CGFloat = 300

    @MainActor
    static func cached(for url: URL) -> UIImage? {
        cache.object(forKey: url.path as NSString)
    }

    /// The video's first frame (rotated the right way), or nil if it can't be read.
    @MainActor
    static func thumbnail(for url: URL) async -> UIImage? {
        let key = url.path as NSString
        if let hit = cache.object(forKey: key) {
            return hit
        }
        let maxSide = maxPixelSize
        // Decode off the main actor.
        let result = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            await grabFirstFrame(from: url, maxSide: maxSide)
        }.value
        if let result {
            cache.setObject(result, forKey: key)
        }
        return result
    }

    private static func grabFirstFrame(from url: URL, maxSide: CGFloat) async -> UIImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        do {
            let result = try await generator.image(at: .zero)
            return UIImage(cgImage: result.image)
        } catch {
            return nil
        }
    }
}
