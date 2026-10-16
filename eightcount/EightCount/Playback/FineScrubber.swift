import SwiftUI

/// A slim ruler strip for frame-accurate fine-tuning.
///
/// It works like a jog wheel: drag your finger sideways and the video
/// moves one frame for every few points of movement (right = forward), so
/// you can land on an exact frame. The tick marks move with the playhead.
/// (The one-frame buttons live in the transport row of the controls.)
@MainActor
struct FineScrubber: View {
    let controller: PlayerController

    /// Where the current drag started; a new value means a new drag.
    @State private var dragStart: CGPoint? = nil
    /// Finger translation already handled in this drag.
    @State private var lastTranslation: CGFloat = 0
    /// Movement not yet turned into a whole frame.
    @State private var leftover: CGFloat = 0
    /// True while a finger is on the strip (resets itself automatically).
    @GestureState private var isTouching = false

    /// Finger movement (points) needed to move one frame. Higher = finer.
    private let pointsPerFrame: CGFloat = 7
    /// Every n-th tick is drawn taller.
    private let ticksPerMajor = 5

    init(controller: PlayerController) {
        self.controller = controller
    }

    var body: some View {
        // Copy values into constants so the Canvas drawing code below
        // doesn't need to reach back into this view.
        let fps = controller.frameRate > 0 ? controller.frameRate : 30
        let frameIndex = controller.currentTime * fps
        let spacing = pointsPerFrame
        let perMajor = ticksPerMajor
        let majorSpacing = spacing * CGFloat(perMajor)
        // Ticks move WITH your finger, like pulling a film strip: as time goes
        // forward the ruler slides left (so the phase shrinks).
        let rawPhase = CGFloat(-frameIndex * Double(spacing)).truncatingRemainder(dividingBy: majorSpacing)
        let phase = rawPhase < 0 ? rawPhase + majorSpacing : rawPhase
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let frameText = "Frame \(Int(frameIndex.rounded()) + 1)"
        let touching = isTouching

        return ZStack {
            shape.fill(Color.white.opacity(0.06))

            // Ruler-style tick marks standing on the bottom edge.
            Canvas { context, size in
                let baseline = size.height - 5
                var minor = Path()
                var major = Path()
                var x = phase - majorSpacing
                var i = 0
                while x <= size.width + majorSpacing {
                    if i % perMajor == 0 {
                        major.move(to: CGPoint(x: x, y: baseline))
                        major.addLine(to: CGPoint(x: x, y: baseline - 13))
                    } else {
                        minor.move(to: CGPoint(x: x, y: baseline))
                        minor.addLine(to: CGPoint(x: x, y: baseline - 7))
                    }
                    x += spacing
                    i += 1
                }
                context.stroke(minor, with: .color(.white.opacity(0.22)), lineWidth: 1)
                context.stroke(major, with: .color(.white.opacity(0.5)), lineWidth: 1.5)
            }

            // The fixed "playhead" in the middle.
            VStack {
                Spacer(minLength: 0)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 2.5, height: 18)
                    .padding(.bottom, 4)
            }

            // Hint (idle) or current frame number (touching), at the top.
            VStack {
                Text(touching ? frameText : "drag to fine-tune")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(touching ? Theme.accent : Color.white.opacity(0.3))
                    .lineLimit(1)
                    .padding(.top, 3)
                Spacer(minLength: 0)
            }
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(touching ? Theme.accent.opacity(0.6) : Theme.hairline, lineWidth: 1)
        }
        .animation(.snappy(duration: 0.2), value: touching)
        .frame(maxWidth: .infinity)
        .frame(height: 32)
        .contentShape(Rectangle())
        .gesture(dragGesture)
        // VoiceOver: swipe up/down to step frames.
        .accessibilityElement()
        .accessibilityLabel("Fine scrub")
        .accessibilityValue(frameText)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: controller.stepFrames(1)
            case .decrement: controller.stepFrames(-1)
            @unknown default: break
            }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isTouching) { _, state, _ in
                state = true
            }
            .onChanged { value in
                // First event of a new drag: reset and pause playback.
                if dragStart != value.startLocation {
                    dragStart = value.startLocation
                    lastTranslation = 0
                    leftover = 0
                    controller.pause()
                }

                // Only use how far the finger moved since the last event.
                let delta = value.translation.width - lastTranslation
                lastTranslation = value.translation.width
                leftover += delta

                // Turn every `pointsPerFrame` of movement into one frame.
                let frames = Int((leftover / pointsPerFrame).rounded(.towardZero))
                if frames != 0 {
                    leftover -= CGFloat(frames) * pointsPerFrame
                    // Like a video editor's timeline: drag LEFT = forward in
                    // time, drag RIGHT = back (the strip follows your finger).
                    controller.stepFrames(-frames)
                }
            }
            .onEnded { _ in
                dragStart = nil
                lastTranslation = 0
                leftover = 0
            }
    }
}
