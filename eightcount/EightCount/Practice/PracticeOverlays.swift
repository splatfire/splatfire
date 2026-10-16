import SwiftUI

/// Pinch-to-zoom state for the practice video: how much it's zoomed in and
/// where it's moved to. The offset is in screen points and kept inside the
/// video, so you can't drag it off into black.
struct VideoZoom: Equatable {
    private(set) var scale: CGFloat = 1
    private(set) var offset: CGSize = .zero
    private var baseScale: CGFloat = 1
    private var baseOffset: CGSize = .zero

    static let maxScale: CGFloat = 4

    var isZoomed: Bool { scale > 1.01 }

    mutating func pinch(_ magnification: CGFloat, in size: CGSize) {
        scale = min(max(baseScale * magnification, 1), Self.maxScale)
        offset = clamped(offset, in: size)
    }

    mutating func drag(_ translation: CGSize, in size: CGSize) {
        offset = clamped(CGSize(width: baseOffset.width + translation.width,
                                height: baseOffset.height + translation.height), in: size)
    }

    /// Finger(s) lifted: remember where we are for the next gesture.
    mutating func settle(in size: CGSize) {
        if scale < 1.05 {
            reset()
            return
        }
        offset = clamped(offset, in: size)
        baseScale = scale
        baseOffset = offset
    }

    mutating func reset() {
        self = VideoZoom()
    }

    private func clamped(_ offset: CGSize, in size: CGSize) -> CGSize {
        let maxX = size.width * (scale - 1) / 2
        let maxY = size.height * (scale - 1) / 2
        return CGSize(width: min(max(offset.width, -maxX), maxX),
                      height: min(max(offset.height, -maxY), maxY))
    }
}

/// Memory test: covers the video so you dance from memory. The music keeps
/// playing and the count stays on screen. Hold to peek at the video.
@MainActor
struct MemoryTestCover: View {
    let controller: PlayerController
    let grid: CountGrid
    @Binding var isPeeking: Bool

    var body: some View {
        // Reads the playhead itself, so only this small view redraws each frame.
        let time = controller.currentTime
        let index = grid.index(at: time)
        let beat = grid.beat(at: time)
        ZStack {
            Color.black.opacity(isPeeking ? 0 : 1)
            if !isPeeking {
                VStack(spacing: 6) {
                    Text("MEMORY TEST")
                        .font(.system(.caption2, design: .rounded).weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(Theme.accent)
                    if grid.isValid {
                        Text(beat.map { "\($0)" } ?? "–")
                            .font(.system(size: 64, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.white)
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.12), value: beat)
                        Text(index.map { "8-count \($0 + 1)" } ?? "Intro")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.secondaryText)
                    } else {
                        Text("Dance it from memory")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Color.white)
                    }
                    Text("Hold to peek")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.top, 4)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.12, maximumDistance: 60, perform: {}, onPressingChanged: { pressing in
            withAnimation(.easeOut(duration: 0.12)) { isPeeking = pressing }
        })
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Touch and hold to see the video")
    }
}

/// "Next ▸ turn left, hit" in the corner of the video.
struct NextMoveHint: View {
    let index: Int
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Text("NEXT \(index + 1)")
                .font(.system(.caption2, design: .rounded).weight(.bold))
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassSurface(Capsule(), fallback: Color.black.opacity(0.6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Next, 8-count \(index + 1): \(text)")
    }

    /// The first line of a note, or nil when there's nothing to show.
    static func text(of note: CountNote?) -> String? {
        guard let note else { return nil }
        let line = note.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The bar under the video while the coach runs (or the cues are fading):
/// what you're drilling, which run, and buttons to skip / restart / stop.
@MainActor
struct CoachBar: View {
    let coach: PracticeCoach
    let cueLevel: Float?
    let onNext: () -> Void
    let onRestart: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if coach.isActive {
                    Text(coach.partName.map { "\(coach.title) · \($0)" } ?? coach.title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accent)
                    Text(coach.stepText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .contentTransition(.numericText())
                    progressDots
                }
                if let cueLevel {
                    Text(cueLevel <= 0.01 ? "Cues faded out – it's all you now"
                                          : "Cues at \(Int((cueLevel * 100).rounded()))% – quieter every run")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            Spacer(minLength: 0)
            if coach.isActive {
                if coach.isFinished {
                    Button(action: onRestart) {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.round(size: 40))
                    .accessibilityLabel("Start the plan again")
                } else {
                    Button(action: onNext) {
                        Image(systemName: "forward.end.fill")
                    }
                    .buttonStyle(.round(size: 40))
                    .accessibilityLabel("Next step")
                }
                Button(action: onStop) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.round(size: 40))
                .accessibilityLabel("Stop the coach")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassSurface(RoundedRectangle(cornerRadius: 16, style: .continuous), fallback: Theme.surface)
        .animation(.snappy, value: coach.stepIndex)
        .animation(.snappy, value: coach.runsDone)
        .sensoryFeedback(.success, trigger: coach.stepIndex)
        .sensoryFeedback(.success, trigger: coach.isFinished) { _, finished in finished }
    }

    private var progressDots: some View {
        HStack(spacing: 4) {
            ForEach(coach.steps.indices, id: \.self) { i in
                Capsule()
                    .fill(i < coach.stepIndex || coach.isFinished ? Theme.accent
                          : i == coach.stepIndex ? Color.white : Color.white.opacity(0.25))
                    .frame(width: i == coach.stepIndex && !coach.isFinished ? 16 : 6, height: 6)
            }
        }
        .padding(.top, 2)
        .accessibilityHidden(true)
    }
}
