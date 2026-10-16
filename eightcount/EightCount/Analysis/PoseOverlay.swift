import SwiftUI

/// A stick-figure drawn over a video. The view fills the same area as the
/// video (any size); the figure is placed inside the part of that area the
/// video really occupies (aspect-fit), and flipped when the video is mirrored.
/// Joints in `highlight` (and the bones between two of them) are drawn red
/// with a pulsing ring, so you can see exactly where a tip applies.
struct PoseOverlay: View {
    let pose: PoseSample?
    /// Video width / height.
    let videoAspect: CGFloat
    let mirrored: Bool
    let color: Color
    let highlight: Set<Joint>
    let label: String?

    @State private var pulse = false

    init(pose: PoseSample?, videoAspect: CGFloat, mirrored: Bool, color: Color,
         highlight: Set<Joint> = [], label: String? = nil) {
        self.pose = pose
        self.videoAspect = videoAspect
        self.mirrored = mirrored
        self.color = color
        self.highlight = highlight
        self.label = label
    }

    /// Strong red for the joints a tip is about.
    private static let alertColor = Color(red: 1.0, green: 0.16, blue: 0.22)

    private static let bones: [(Joint, Joint)] = [
        (.nose, .neck),
        (.neck, .leftShoulder), (.neck, .rightShoulder),
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.neck, .root),
        (.root, .leftHip), (.root, .rightHip),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
    ]

    var body: some View {
        GeometryReader { geometry in
            let points = screenPoints(in: geometry.size)
            ZStack {
                Canvas { context, _ in
                    drawBones(into: &context, points: points)
                }
                ForEach(ringJoints(in: points), id: \.self) { joint in
                    if let p = points[joint] {
                        Circle()
                            .stroke(Self.alertColor, lineWidth: 2.5)
                            .frame(width: 26, height: 26)
                            .scaleEffect(pulse ? 1.6 : 0.85)
                            .opacity(pulse ? 0.1 : 0.95)
                            .position(p)
                    }
                }
                if let label, !label.isEmpty, let spot = labelSpot(points: points, size: geometry.size) {
                    Text(label)
                        .font(.system(.caption2, design: .rounded).weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(color.opacity(0.92)))
                        .position(spot)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    // MARK: Geometry

    /// Joint positions in points inside `size`.
    private func screenPoints(in size: CGSize) -> [Joint: CGPoint] {
        guard let pose else { return [:] }
        let fit = CoachSupport.aspectFitRect(aspect: videoAspect, in: size)
        var result: [Joint: CGPoint] = [:]
        for (joint, p) in pose.joints {
            let x = mirrored ? 1 - Double(p.x) : Double(p.x)
            result[joint] = CGPoint(x: fit.minX + CGFloat(x) * fit.width,
                                    y: fit.minY + CGFloat(p.y) * fit.height)
        }
        return result
    }

    private func ringJoints(in points: [Joint: CGPoint]) -> [Joint] {
        highlight.filter { points[$0] != nil }.sorted { $0.rawValue < $1.rawValue }
    }

    /// Where the label goes: just above the head.
    private func labelSpot(points: [Joint: CGPoint], size: CGSize) -> CGPoint? {
        guard let anchor = points[.nose] ?? points[.neck] else { return nil }
        let x = min(max(anchor.x, 40), max(40, size.width - 40))
        let y = max(14, anchor.y - 26)
        return CGPoint(x: x, y: y)
    }

    // MARK: Drawing

    private func drawBones(into context: inout GraphicsContext, points: [Joint: CGPoint]) {
        guard !points.isEmpty else { return }
        let outline = Color.black.opacity(0.55)
        let normal = color.opacity(0.85)
        let alert = Self.alertColor

        // Normal bones first, red ones on top.
        for pass in 0..<2 {
            for (a, b) in Self.bones {
                guard let pa = points[a], let pb = points[b] else { continue }
                let hot = highlight.contains(a) && highlight.contains(b)
                if hot != (pass == 1) { continue }
                var path = Path()
                path.move(to: pa)
                path.addLine(to: pb)
                let width: CGFloat = hot ? 5 : 3
                context.stroke(path, with: .color(outline),
                               style: StrokeStyle(lineWidth: width + 2, lineCap: .round))
                context.stroke(path, with: .color(hot ? alert : normal),
                               style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
        }

        // Joint dots.
        for (joint, p) in points {
            let hot = highlight.contains(joint)
            let radius: CGFloat = hot ? 6 : (joint == .nose ? 5 : 3.5)
            let rect = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
            let dot = Path(ellipseIn: rect)
            context.fill(dot, with: .color(hot ? alert : normal))
            context.stroke(dot, with: .color(outline), lineWidth: 1)
        }
    }
}
