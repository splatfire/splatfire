import Foundation
import AVFoundation
import CoreGraphics
import UIKit

/// Grabs a still frame from a video file as JPEG data (for pose snapshots).
enum FrameGrabber {
    enum GrabError: LocalizedError {
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .encodingFailed:
                return "The picture could not be saved as a JPEG."
            }
        }
    }

    /// The frame at `seconds` as JPEG.
    /// - Parameter mirrored: flip left/right, to match a mirrored video view.
    /// This is not tied to the main thread; the heavy work runs in the background.
    static func jpegData(from videoURL: URL, at seconds: Double, mirrored: Bool) async throws -> Data {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        // Use the video's rotation (phone videos are often stored sideways).
        generator.appliesPreferredTrackTransform = true
        // Exactly the frame you're looking at, not the nearest keyframe.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 1280, height: 1280)

        let safeSeconds = seconds.isFinite ? max(0, seconds) : 0
        let time = CMTime(seconds: safeSeconds, preferredTimescale: 600)

        let cgImage: CGImage
        do {
            let result = try await generator.image(at: time)
            cgImage = result.image
        } catch {
            // Right at the very end of a video an exact frame may not exist.
            // Try again, allowing a frame up to 0.2 s earlier.
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
            let result = try await generator.image(at: time)
            cgImage = result.image
        }

        return try encode(cgImage, mirrored: mirrored)
    }

    /// Turns the frame into JPEG, flipping it first if needed.
    private static func encode(_ cgImage: CGImage, mirrored: Bool) throws -> Data {
        var image = UIImage(cgImage: cgImage)

        if mirrored {
            let size = CGSize(width: cgImage.width, height: cgImage.height)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1          // keep the real pixel size
            format.opaque = true      // video frames have no transparency
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            let original = image
            image = renderer.image { context in
                // Move to the right edge, then flip horizontally.
                context.cgContext.translateBy(x: size.width, y: 0)
                context.cgContext.scaleBy(x: -1, y: 1)
                original.draw(in: CGRect(origin: .zero, size: size))
            }
        }

        guard let data = image.jpegData(compressionQuality: 0.75) else {
            throw GrabError.encodingFailed
        }
        return data
    }
}
