import Foundation
import AVFoundation
import Vision
import CoreGraphics

// Step 1 of the dance analysis: find the dancer's body joints in a video.
// Everything here runs on the iPhone (Apple's Vision framework). Nothing is
// uploaded anywhere.

/// The body joints we look at (a simple copy of Vision's joint names, so the
/// rest of the analysis does not need to import Vision).
enum Joint: String, CaseIterable, Codable, Sendable {
    case nose, neck
    case leftShoulder, rightShoulder
    case leftElbow, rightElbow
    case leftWrist, rightWrist
    case root
    case leftHip, rightHip
    case leftKnee, rightKnee
    case leftAnkle, rightAnkle

    /// The matching Vision joint name.
    var visionName: VNHumanBodyPoseObservation.JointName {
        switch self {
        case .nose: return .nose
        case .neck: return .neck
        case .leftShoulder: return .leftShoulder
        case .rightShoulder: return .rightShoulder
        case .leftElbow: return .leftElbow
        case .rightElbow: return .rightElbow
        case .leftWrist: return .leftWrist
        case .rightWrist: return .rightWrist
        case .root: return .root
        case .leftHip: return .leftHip
        case .rightHip: return .rightHip
        case .leftKnee: return .leftKnee
        case .rightKnee: return .rightKnee
        case .leftAnkle: return .leftAnkle
        case .rightAnkle: return .rightAnkle
        }
    }
}

/// One person's pose in one video frame. Plain values only, so it can be
/// passed between threads freely.
struct PoseSample: Sendable {
    /// Video time in seconds.
    var time: Double
    /// Joint positions, normalized 0...1, origin at the TOP-left of the image.
    var joints: [Joint: CGPoint]
    /// Image width / height (needed so angles are not squashed).
    var aspect: Double
}

enum PoseExtractor {
    /// How many frames per second we look at.
    static let framesPerSecond = 10.0
    /// Safety limit so a very long video cannot take forever.
    static let maxFrames = 2400
    /// Joints Vision is less sure about than this are ignored.
    static let minConfidence: Float = 0.3
    /// A frame needs at least this many joints to count as "a person found".
    static let minJoints = 6

    /// Length of the video in seconds.
    static func duration(of url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let time = try await asset.load(.duration)
        let seconds = time.seconds
        return seconds.isFinite ? max(0, seconds) : 0
    }

    /// Evenly spaced times (about 10 per second) from `start` to `end`.
    static func sampleTimes(from start: Double, to end: Double) -> [Double] {
        guard start.isFinite, end.isFinite, end > start else { return [] }
        var step = 1.0 / framesPerSecond
        var count = Int(((end - start) / step).rounded(.down)) + 1
        if count > maxFrames {
            count = maxFrames
            step = (end - start) / Double(maxFrames - 1)
        }
        return (0..<count).map { start + Double($0) * step }
    }

    /// Finds the dancer's pose at each of `times` (seconds) in the video.
    /// Frames where nobody is found are simply left out.
    /// - Parameter progress: called with 0...1 as frames are done (any thread).
    /// Throws `CancellationError` if the surrounding task is cancelled.
    static func extract(
        from url: URL,
        at times: [Double],
        progress: @Sendable (Double) -> Void
    ) async throws -> [PoseSample] {
        guard !times.isEmpty else { return [] }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        // Use the video's rotation (phone videos are often stored sideways).
        generator.appliesPreferredTrackTransform = true
        // Small frames are plenty for pose detection and much faster.
        generator.maximumSize = CGSize(width: 640, height: 640)
        // Any frame within 0.05 s is fine (much faster than exact frames).
        let tolerance = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let cmTimes = times.map { CMTime(seconds: $0, preferredTimescale: 600) }
        var samples: [PoseSample] = []
        var finished = 0

        for try await result in generator.images(for: cmTimes) {
            try Task.checkCancellation()
            finished += 1
            progress(Double(finished) / Double(cmTimes.count))

            // A frame that could not be read is skipped, not fatal.
            let cgImage: CGImage
            do {
                cgImage = try result.image
            } catch {
                continue
            }
            let time = result.requestedTime.seconds
            if let sample = detectPose(in: cgImage, at: time) {
                samples.append(sample)
            }
        }

        try Task.checkCancellation()
        progress(1)
        samples.sort { $0.time < $1.time }
        return samples
    }

    /// The dancer's pose in ONE frame of the video (nil if nobody is found).
    /// `time` is in the video's own seconds. Used by the "show me" view.
    static func pose(in url: URL, at time: Double) async -> PoseSample? {
        guard time.isFinite else { return nil }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        let tolerance = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var seconds = max(0, time)
        if let length = try? await asset.load(.duration).seconds, length.isFinite, length > 0 {
            seconds = min(seconds, max(0, length - 0.05))
        }
        do {
            let result = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
            if Task.isCancelled { return nil }
            return detectPose(in: result.image, at: seconds)
        } catch {
            return nil
        }
    }

    /// Runs Vision on one image and returns the largest person's joints.
    private static func detectPose(in image: CGImage, at time: Double) -> PoseSample? {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        let observations: [VNHumanBodyPoseObservation] = request.results ?? []
        guard !observations.isEmpty else { return nil }

        // Keep the person with the biggest box around their joints.
        var best: [Joint: CGPoint] = [:]
        var bestArea = -1.0
        for observation in observations {
            guard let all = try? observation.recognizedPoints(.all) else { continue }
            var joints: [Joint: CGPoint] = [:]
            for joint in Joint.allCases {
                guard let point = all[joint.visionName], point.confidence > minConfidence else { continue }
                // Vision's origin is bottom-left; ours is top-left.
                joints[joint] = CGPoint(x: Double(point.location.x), y: 1 - Double(point.location.y))
            }
            guard joints.count >= minJoints else { continue }
            let area = boundingArea(of: joints)
            if area > bestArea {
                bestArea = area
                best = joints
            }
        }
        guard !best.isEmpty, image.height > 0 else { return nil }
        return PoseSample(
            time: time,
            joints: best,
            aspect: Double(image.width) / Double(image.height)
        )
    }

    /// Area of the smallest box that contains all the points.
    private static func boundingArea(of joints: [Joint: CGPoint]) -> Double {
        var minX = Double.greatestFiniteMagnitude, maxX = -Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        for point in joints.values {
            minX = min(minX, Double(point.x)); maxX = max(maxX, Double(point.x))
            minY = min(minY, Double(point.y)); maxY = max(maxY, Double(point.y))
        }
        return max(0, maxX - minX) * max(0, maxY - minY)
    }
}
