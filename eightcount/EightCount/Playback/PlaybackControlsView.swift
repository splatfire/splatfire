import SwiftUI
import UIKit

/// Calm, minimal playback controls (about 260 pt tall), top to bottom:
///
///  1. slim timeline scrubber + times + current 8-count chip
///  2. fine-tune ruler (`FineScrubber`)
///  3. transport: [-2s] [frame ◀] [ Play / Pause ] [frame ▶] [+2s]
///  4. speeds (pill picker) + mirror + snapshot
///  5. one capsule loop bar: [A] [B] [Loop] [✕]
@MainActor
struct PlaybackControlsView: View {
    let controller: PlayerController
    /// e.g. "8-count 5 · 3". Hidden when nil.
    let countLabel: String?
    /// Shows a camera button when set.
    let onSnapshot: (() -> Void)?

    /// While the timeline is being dragged we show this value instead of
    /// `controller.currentTime`, so time updates don't fight your finger.
    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0
    @State private var wasPlayingBeforeScrub = false
    /// Bumped whenever A or B is set, to trigger a haptic tap.
    @State private var loopHaptic = 0

    init(controller: PlayerController, countLabel: String?, onSnapshot: (() -> Void)?) {
        self.controller = controller
        self.countLabel = countLabel
        self.onSnapshot = onSnapshot
    }

    var body: some View {
        GlassGroup(spacing: 10) {
            VStack(spacing: 10) {
                VStack(spacing: 2) {
                    timeline
                    timeLabels
                }
                FineScrubber(controller: controller)
                    .padding(.top, 2)
                transportRow
                optionsRow
                loopBar
            }
        }
        .padding(.horizontal, 16)
        .disabled(!controller.isReady)
        .opacity(controller.isReady ? 1 : 0.45)
        .animation(.snappy, value: controller.isReady)
        .sensoryFeedback(.impact(weight: .medium), trigger: loopHaptic)
    }

    // MARK: - 1. Timeline

    private var shownTime: Double {
        isScrubbing ? scrubTime : controller.currentTime
    }

    private var timeline: some View {
        PlaybackTimelineBar(
            value: shownTime,
            duration: controller.duration,
            loopStart: controller.loopStart,
            loopEnd: controller.loopEnd,
            isDragging: isScrubbing,
            onScrub: { time in
                if !isScrubbing {
                    // Finger down: remember play state and pause.
                    wasPlayingBeforeScrub = controller.isPlaying
                    isScrubbing = true
                    controller.pause()
                }
                scrubTime = time
                controller.seek(to: time)   // live preview while dragging
            },
            onScrubEnd: { time in
                // Finger up: land exactly where the knob is.
                controller.seek(to: time)
                isScrubbing = false
                if wasPlayingBeforeScrub {
                    controller.play(countIn: false)
                }
            },
            onNudge: { seconds in
                controller.skip(by: seconds)
            }
        )
    }

    private var timeLabels: some View {
        let remaining = max(controller.duration - shownTime, 0)
        return ZStack {
            HStack {
                Text(formatTime(shownTime))
                Spacer(minLength: 8)
                Text(formatTime(-remaining))
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(Theme.secondaryText)
            .lineLimit(1)

            if let countLabel = countLabel {
                Text(countLabel)
                    .font(.system(.caption2, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.accent.opacity(0.16)))
                    .transition(.opacity)
            }
        }
        .animation(.snappy, value: countLabel)
        .accessibilityElement(children: .combine)
    }

    // MARK: - 4. Transport

    private var transportRow: some View {
        HStack(spacing: 16) {
            Button {
                controller.skip(by: -2)
            } label: {
                skipIcon("gobackward")
            }
            .buttonStyle(.round(size: 48))
            .accessibilityLabel("Back 2 seconds")

            Button {
                controller.stepFrames(-1)
            } label: {
                Image(systemName: "backward.frame.fill")
            }
            .buttonStyle(.round(size: 48))
            .buttonRepeatBehavior(.enabled)
            .accessibilityLabel("Back one frame")

            Button {
                controller.togglePlayPause()
            } label: {
                Image(systemName: controller.isPlaying || controller.isCountingIn ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.round(size: 68, prominent: true))
            .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")

            Button {
                controller.stepFrames(1)
            } label: {
                Image(systemName: "forward.frame.fill")
            }
            .buttonStyle(.round(size: 48))
            .buttonRepeatBehavior(.enabled)
            .accessibilityLabel("Forward one frame")

            Button {
                controller.skip(by: 2)
            } label: {
                skipIcon("goforward")
            }
            .buttonStyle(.round(size: 48))
            .accessibilityLabel("Forward 2 seconds")
        }
        .animation(.snappy, value: controller.isPlaying)
        .frame(maxWidth: .infinity)
    }

    /// "gobackward" / "goforward" with a tiny "2" inside the arrow circle
    /// (there is no ready-made 2-second symbol).
    private func skipIcon(_ systemImage: String) -> some View {
        ZStack {
            Image(systemName: systemImage)
            Text("2")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .offset(y: 0.5)
        }
    }

    // MARK: - 5. Speed + mirror + snapshot

    private var speedOptions: [PillPicker<Float>.Option] {
        PlayerController.speeds.map { speed in
            let title = speedText(speed)
            return PillPicker<Float>.Option(
                value: speed,
                title: title,
                accessibilityLabel: "Speed \(title)"
            )
        }
    }

    private var optionsRow: some View {
        HStack(spacing: 10) {
            PillPicker<Float>(
                options: speedOptions,
                selection: controller.rate,
                onSelect: { controller.setRate($0) }
            )
            .frame(maxWidth: .infinity)

            Button {
                controller.isMirrored.toggle()
            } label: {
                Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
            }
            .buttonStyle(.round(size: Theme.controlHeight, isOn: controller.isMirrored))
            .accessibilityLabel(controller.isMirrored ? "Mirror on" : "Mirror off")

            if let onSnapshot = onSnapshot {
                Button {
                    onSnapshot()
                } label: {
                    Image(systemName: "camera.fill")
                }
                .buttonStyle(.round(size: Theme.controlHeight))
                .accessibilityLabel("Take snapshot")
            }
        }
        .animation(.snappy, value: controller.isMirrored)
    }

    /// 0.25 → "0.25×", 1.0 → "1×".
    private func speedText(_ speed: Float) -> String {
        let value = Double(speed)
        if value == value.rounded() {
            return "\(Int(value))×"
        }
        return "\(value)×"
    }

    // MARK: - 6. Loop bar

    private var hasBothLoopPoints: Bool {
        controller.loopStart != nil && controller.loopEnd != nil
    }

    private var hasAnyLoopPoint: Bool {
        controller.loopStart != nil || controller.loopEnd != nil
    }

    private var loopTitle: String {
        if let index = controller.loopedEightCount {
            return "8-count \(index + 1)"
        }
        return "Loop"
    }

    private var loopBar: some View {
        let looping = controller.isLooping
        return HStack(spacing: 0) {
            loopPointSegment(
                name: "A",
                time: controller.loopStart,
                label: "Set loop start A"
            ) {
                loopHaptic += 1
                controller.setA()
            }

            loopDivider

            loopPointSegment(
                name: "B",
                time: controller.loopEnd,
                label: "Set loop end B"
            ) {
                loopHaptic += 1
                controller.setB()
            }

            loopDivider

            Button {
                controller.toggleLoop()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "repeat")
                    Text(loopTitle)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(looping ? Color.black : Color.white)
                .frame(maxWidth: .infinity, minHeight: Theme.controlHeight)
                .background {
                    if looping {
                        Capsule().fill(Theme.loopColor).padding(3)
                    }
                }
                .contentShape(Capsule())
            }
            .buttonStyle(LoopBarSegmentStyle())
            .disabled(!hasBothLoopPoints)
            .opacity(hasBothLoopPoints ? 1 : 0.4)
            .accessibilityLabel(looping ? "Loop on" : "Loop off")

            loopDivider

            Button {
                controller.clearLoop()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: Theme.controlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(LoopBarSegmentStyle())
            .disabled(!hasAnyLoopPoint)
            .opacity(hasAnyLoopPoint ? 1 : 0.4)
            .accessibilityLabel("Clear loop")
        }
        .frame(height: Theme.controlHeight)
        .glassSurface(Capsule(), fallback: Theme.surface)
        .animation(.snappy, value: looping)
        .animation(.snappy, value: controller.loopStart)
        .animation(.snappy, value: controller.loopEnd)
        .animation(.snappy, value: controller.loopedEightCount)
    }

    private var loopDivider: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: 1, height: 20)
    }

    /// "Set A" before it's set; afterwards "A 0:12.3" with the time tinted.
    private func loopPointSegment(
        name: String,
        time: Double?,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let time = time {
                    Text(name)
                    Text(shortTime(time))
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.loopColor)
                        .minimumScaleFactor(0.7)
                } else {
                    Text("Set \(name)")
                        .foregroundStyle(Color.white.opacity(0.85))
                }
            }
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: Theme.controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(LoopBarSegmentStyle())
        .accessibilityLabel(label)
        .accessibilityValue(time.map { formatTime($0) } ?? "not set")
    }

    /// "0:12.3" (one decimal) for the compact loop bar.
    private func shortTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let minutes = Int(seconds) / 60
        let secs = seconds - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, secs)
    }
}

// MARK: - Loop bar segment style

/// Plain segment inside the loop capsule: just dims a little while pressed.
private struct LoopBarSegmentStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Timeline scrubber

/// A slim custom scrubber: 4 pt track, accent fill, 14 pt knob, and a 32 pt
/// tall hit area where you can tap or drag to seek. Loop points A/B show up
/// as tiny ticks with a faint band between them.
private struct PlaybackTimelineBar: View {
    let value: Double
    let duration: Double
    let loopStart: Double?
    let loopEnd: Double?
    let isDragging: Bool
    let onScrub: (Double) -> Void
    let onScrubEnd: (Double) -> Void
    let onNudge: (Double) -> Void

    private let knobSize: CGFloat = 14
    private let trackHeight: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let inset = knobSize / 2
            let usable = max(geo.size.width - knobSize, 1)
            let x = inset + usable * fraction(of: value)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.15))
                    .frame(height: trackHeight)

                if let a = loopStart, let b = loopEnd, duration > 0 {
                    let ax = inset + usable * fraction(of: min(a, b))
                    let bx = inset + usable * fraction(of: max(a, b))
                    Rectangle()
                        .fill(Theme.loopColor.opacity(0.28))
                        .frame(width: max(bx - ax, 0), height: trackHeight)
                        .offset(x: ax)
                }

                Capsule()
                    .fill(Theme.accent)
                    .frame(width: x, height: trackHeight)

                if duration > 0 {
                    if let a = loopStart {
                        loopTick(at: inset + usable * fraction(of: a))
                    }
                    if let b = loopEnd {
                        loopTick(at: inset + usable * fraction(of: b))
                    }
                }

                Circle()
                    .fill(Color.white)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .scaleEffect(isDragging ? 1.35 : 1)
                    .animation(.snappy, value: isDragging)
                    .offset(x: x - inset)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        onScrub(time(atX: drag.location.x, inset: inset, usable: usable))
                    }
                    .onEnded { drag in
                        onScrubEnd(time(atX: drag.location.x, inset: inset, usable: usable))
                    }
            )
        }
        .frame(height: 32)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Video position")
        .accessibilityValue(formatTime(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onNudge(1)
            case .decrement: onNudge(-1)
            @unknown default: break
            }
        }
    }

    private func loopTick(at x: CGFloat) -> some View {
        Capsule()
            .fill(Theme.loopColor)
            .frame(width: 2, height: 12)
            .offset(x: x - 1)
    }

    private func fraction(of seconds: Double) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(seconds / duration, 0), 1))
    }

    private func time(atX x: CGFloat, inset: CGFloat, usable: CGFloat) -> Double {
        let f = min(max((x - inset) / usable, 0), 1)
        return Double(f) * max(duration, 0)
    }
}
