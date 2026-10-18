import Foundation
import CoreGraphics

// Helpers for the "show me on the video" coach: find the body in one frame,
// decide which joints belong to a tip, and line up a see-through copy of the
// tutorial dancer on top of you. All on the iPhone.

/// The body pose in one frame of the tutorial and in one frame of your take.
struct CoachPoses: Sendable, Equatable {
    var tutorial: PoseSample?
    var take: PoseSample?
}

/// `PoseSample` compared by value (written by hand: Swift can only generate
/// this in the file where the type is declared).
extension PoseSample: Equatable {
    static func == (lhs: PoseSample, rhs: PoseSample) -> Bool {
        lhs.time == rhs.time && lhs.aspect == rhs.aspect && lhs.joints == rhs.joints
    }
}

enum CoachSupport {
    // MARK: Poses

    /// Body pose in ONE frame of each video (Vision, one frame each, off the
    /// main actor). Times are in each video's own seconds.
    static func poses(tutorialURL: URL, tutorialTime: Double,
                      takeURL: URL, takeTime: Double) async -> CoachPoses {
        await offMain {
            async let tutorial = PoseExtractor.pose(in: tutorialURL, at: tutorialTime)
            async let take = PoseExtractor.pose(in: takeURL, at: takeTime)
            let tutorialPose = await tutorial
            let takePose = await take
            return CoachPoses(tutorial: tutorialPose, take: takePose)
        }
    }

    /// Runs `work` on a background task (stops it if the caller is cancelled).
    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T {
        let task = Task.detached(priority: .userInitiated) { await work() }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: Which joints belong to a tip

    /// Joints to paint red for a finding's body part (see `PoseComparer`:
    /// "Left elbow", "Right arm", "Left hand", "Knees", "Hips", "Torso",
    /// "Move size", "Timing"). Case-insensitive; unknown names give nothing.
    /// Same joints on the other side of the body (left ↔ right). Used for the
    /// tutorial skeleton when only one of the two videos is shown mirrored:
    /// then the tutorial's matching limb is on the opposite side.
    static func swappedSides(_ joints: Set<Joint>) -> Set<Joint> {
        Set(joints.map { joint in
            let name = joint.rawValue
            if name.hasPrefix("left") {
                return Joint(rawValue: "right" + name.dropFirst(4)) ?? joint
            }
            if name.hasPrefix("right") {
                return Joint(rawValue: "left" + name.dropFirst(5)) ?? joint
            }
            return joint
        })
    }

    static func joints(forBodyPart bodyPart: String) -> Set<Joint> {
        let s = bodyPart.lowercased()
        if s.contains("move size") || s.contains("timing") { return [] }

        if s.contains("knee") || s.contains("leg") || s.contains("ankle") {
            return sided(s,
                         left: [.leftHip, .leftKnee, .leftAnkle],
                         right: [.rightHip, .rightKnee, .rightAnkle])
        }
        if s.contains("hip") {
            return sided(s, left: [.root, .leftHip], right: [.root, .rightHip])
        }
        if s.contains("torso") || s.contains("posture") || s.contains("lean")
            || s.contains("upper body") || s.contains("back") || s.contains("spine") {
            return [.neck, .root, .leftShoulder, .rightShoulder, .leftHip, .rightHip]
        }
        if s.contains("arm") || s.contains("elbow") || s.contains("hand")
            || s.contains("wrist") || s.contains("shoulder") {
            return sided(s,
                         left: [.leftShoulder, .leftElbow, .leftWrist],
                         right: [.rightShoulder, .rightElbow, .rightWrist])
        }
        return []
    }

    /// Only the left or right set if the text says which; otherwise both.
    private static func sided(_ text: String, left: [Joint], right: [Joint]) -> Set<Joint> {
        let hasLeft = text.contains("left")
        let hasRight = text.contains("right")
        if hasLeft && !hasRight { return Set(left) }
        if hasRight && !hasLeft { return Set(right) }
        return Set(left + right)
    }

    // MARK: Body box

    /// Box around a pose's joints, padded by 8% on every side, clamped to 0...1.
    /// Normalized, top-left origin. nil if the joints are too few or flat.
    static func bodyBox(of sample: PoseSample, padding: Double = 0.08) -> CGRect? {
        let points = Array(sample.joints.values)
        guard points.count >= 2 else { return nil }
        var minX = Double.greatestFiniteMagnitude, maxX = -Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        for p in points {
            minX = min(minX, Double(p.x)); maxX = max(maxX, Double(p.x))
            minY = min(minY, Double(p.y)); maxY = max(maxY, Double(p.y))
        }
        let width = maxX - minX
        let height = maxY - minY
        guard width > 0.001, height > 0.001 else { return nil }
        let x0 = max(0, minX - width * padding)
        let y0 = max(0, minY - height * padding)
        let x1 = min(1, maxX + width * padding)
        let y1 = min(1, maxY + height * padding)
        guard x1 > x0, y1 > y0 else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Average body box of the main dancer over about 6 frames evenly spaced
    /// from `start` to `end` (video seconds). Normalized 0...1, top-left
    /// origin, in the video's own (UNMIRRORED) coordinates. nil if no body.
    static func averageBodyBox(url: URL, from start: Double, to end: Double) async -> CGRect? {
        guard start.isFinite, end.isFinite else { return nil }
        let count = 6
        let low = max(0, min(start, end))
        let high = max(low, max(start, end))
        let times: [Double] = high - low < 0.05
            ? [low]
            : (0..<count).map { low + (high - low) * Double($0) / Double(count - 1) }

        return await offMain {
            guard let samples = try? await PoseExtractor.extract(from: url, at: times, progress: { _ in }),
                  !samples.isEmpty else { return nil }
            var sumX0 = 0.0, sumY0 = 0.0, sumX1 = 0.0, sumY1 = 0.0
            var found = 0.0
            for sample in samples {
                guard let box = CoachSupport.bodyBox(of: sample) else { continue }
                sumX0 += Double(box.minX); sumY0 += Double(box.minY)
                sumX1 += Double(box.maxX); sumY1 += Double(box.maxY)
                found += 1
            }
            guard found > 0 else { return nil }
            return CGRect(x: sumX0 / found, y: sumY0 / found,
                          width: (sumX1 - sumX0) / found, height: (sumY1 - sumY0) / found)
        }
    }

    // MARK: Ghost overlay math

    /// Rect a video of aspect (width / height) fills when shown aspect-fit
    /// (whole video visible, centered) in `container`.
    static func aspectFitRect(aspect: CGFloat, in container: CGSize) -> CGRect {
        guard container.width > 0, container.height > 0 else { return .zero }
        guard aspect.isFinite, aspect > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let containerAspect = container.width / container.height
        let size: CGSize
        if aspect > containerAspect {
            size = CGSize(width: container.width, height: container.width / aspect)
        } else {
            size = CGSize(width: container.height * aspect, height: container.height)
        }
        return CGRect(x: (container.width - size.width) / 2,
                      y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// How to scale and move the tutorial layer so the tutorial dancer's body
    /// box lands on yours. Apply as `.scaleEffect(scale).offset(offset)` on a
    /// layer that fills `container`.
    ///
    /// Math (all in points, inside `container`):
    ///  1. Each video is aspect-fit, so a normalized box (x, y, w, h) becomes
    ///     fit.origin + (x, y) * fit.size. A mirrored video flips x first:
    ///     x' = 1 - x - w.
    ///  2. scale  = takeBox.height / tutorialBox.height, clamped to 0.4...3.
    ///  3. `scaleEffect` grows the layer about the container center C, so the
    ///     tutorial box center T moves to C + (T - C) * scale.
    ///  4. offset = takeBox.center - (C + (T - C) * scale).
    static func ghostTransform(tutorialBox: CGRect, tutorialAspect: CGFloat, tutorialMirrored: Bool,
                               takeBox: CGRect, takeAspect: CGFloat, takeMirrored: Bool,
                               container: CGSize) -> (scale: CGFloat, offset: CGSize) {
        guard container.width > 0, container.height > 0 else { return (1, .zero) }
        let tutorialPts = pointsRect(of: tutorialBox, aspect: tutorialAspect,
                                     mirrored: tutorialMirrored, in: container)
        let takePts = pointsRect(of: takeBox, aspect: takeAspect,
                                 mirrored: takeMirrored, in: container)
        guard tutorialPts.height > 1, takePts.height > 1 else { return (1, .zero) }

        let scale = min(3, max(0.4, takePts.height / tutorialPts.height))
        let center = CGPoint(x: container.width / 2, y: container.height / 2)
        let tutorialCenter = CGPoint(x: tutorialPts.midX, y: tutorialPts.midY)
        let scaledCenter = CGPoint(x: center.x + (tutorialCenter.x - center.x) * scale,
                                   y: center.y + (tutorialCenter.y - center.y) * scale)
        let offset = CGSize(width: takePts.midX - scaledCenter.x,
                            height: takePts.midY - scaledCenter.y)
        return (scale, offset)
    }

    /// A normalized box -> points, inside the aspect-fit video in `container`.
    private static func pointsRect(of box: CGRect, aspect: CGFloat, mirrored: Bool,
                                   in container: CGSize) -> CGRect {
        let fit = aspectFitRect(aspect: aspect, in: container)
        let x = mirrored ? 1 - box.minX - box.width : box.minX
        return CGRect(x: fit.minX + x * fit.width,
                      y: fit.minY + box.minY * fit.height,
                      width: box.width * fit.width,
                      height: box.height * fit.height)
    }
}
