import AVFoundation
import QuartzCore
import SwiftData
import SwiftUI
import UIKit

/// Watch yourself (a "take") next to the tutorial, perfectly in sync, with the
/// tutorial's music.
///
///  - Landscape: YOU on the left, TUTORIAL on the right.
///  - Portrait:  YOU on top, TUTORIAL at the bottom.
///  - "Ghost" mode: the tutorial is a see-through ghost over you, auto-aligned
///    to your body (drag / pinch to fine-tune).
///  - "Coach" mode: AI issues are drawn right on the video frames (skeletons
///    with the problem joints in red) and a small card explains each one.
///
/// Safe area: the VIDEOS are full-bleed (they ignore the safe area), but every
/// control lives in a layer that respects it, so nothing hides under the
/// Dynamic Island, the notch or the home indicator.
///
/// Present it with `.fullScreenCover`. It has its own close button.
@MainActor
struct CompareView: View {
    let project: Project
    let take: Take
    let tutorialMirrored: Bool
    /// Start playing (from the start of the range, looping) as soon as both
    /// videos are ready.
    let autoPlay: Bool
    /// When set, the top bar shows a red "Record again" button that calls it.
    let onRecordAgain: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var playback: SyncedPlayback

    /// true = two videos next to each other, false = ghost overlay (default).
    @State private var isSideBySide = false
    /// Your video is flipped by default, like looking in a mirror.
    /// (The recorded file itself is NOT mirrored.)
    @State private var mirrorMe = true
    @State private var mirrorTutorial: Bool
    /// How visible the tutorial ghost is in ghost mode.
    @State private var ghostOpacity = 0.5
    @State private var controlsVisible = true

    @State private var showSync = false
    @State private var showAnalysis = false
    @State private var showExport = false
    /// Auto-play happens once per screen.
    @State private var didAutoPlay = false

    /// While the slider thumb is dragged we show this value instead of the
    /// real playhead, so updates don't fight your finger.
    @State private var isScrubbing = false
    @State private var scrubTime = 0.0
    @State private var wasPlayingBeforeScrub = false

    // Ghost alignment (computed once, on demand).
    @State private var alignState: CompareGhostAlignState = .idle
    @State private var alignNonce = 0
    @State private var tutorialBox: CGRect? = nil
    @State private var takeBox: CGRect? = nil
    @State private var tutorialAspect: CGFloat? = nil
    @State private var takeAspect: CGFloat? = nil
    /// Hand-made fine-tuning on top of the automatic alignment.
    @State private var ghostPan: CGSize = .zero
    @State private var ghostZoom: CGFloat = 1
    @GestureState private var panDelta: CGSize = .zero
    @GestureState private var zoomDelta: CGFloat = 1

    // Coach mode.
    @State private var report: AnalysisReport?
    @State private var coachFindings: [AnalysisReport.Finding] = []
    @State private var coachIndex = 0
    @State private var coachPoses: CoachPoses? = nil
    @State private var isReplaying = false
    @State private var replayTask: Task<Void, Never>? = nil
    @State private var replayRestore: CompareReplayRestore? = nil
    /// Identifies this screen to the Apple Watch remote.
    @State private var watchID = UUID()

    init(project: Project, take: Take, tutorialMirrored: Bool,
         autoPlay: Bool = true, onRecordAgain: (() -> Void)? = nil) {
        self.project = project
        self.take = take
        self.tutorialMirrored = tutorialMirrored
        self.autoPlay = autoPlay
        self.onRecordAgain = onRecordAgain
        _playback = State(initialValue: SyncedPlayback(project: project, take: take))
        _mirrorTutorial = State(initialValue: tutorialMirrored)
        _report = State(initialValue: take.analysisReport)
    }

    // MARK: - Body

    var body: some View {
        // This reader RESPECTS the safe area, so its insets are the real ones.
        // Only the videos (a background layer) ignore the safe area.
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let insets = geo.safeAreaInsets
            VStack(spacing: 0) {
                videoRegion(landscape: landscape, insets: insets)
                // Portrait: the controls sit under the videos so they never cover them.
                if !landscape && controlsVisible {
                    portraitBar
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden()
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .onAppear {
            OrientationLock.allowLandscape()
            SyncedPlayback.activateAudioSession()
            WatchRemoteHandlers.attachCompare(id: watchID, project: project, playback: playback)
        }
        .task {
            await playback.load()
            startAutoPlayIfNeeded()
        }
        .task(id: alignTrigger) {
            await alignGhostIfNeeded()
        }
        .task(id: coachKey) {
            await loadCoachPoses()
        }
        .onDisappear {
            WatchRemote.shared.detach(id: watchID)
            cancelReplay()
            OrientationLock.portraitOnly()
            playback.tearDown()
            try? modelContext.save()
        }
        .sheet(isPresented: $showExport) {
            ExportTakeSheet(take: take, project: project,
                            mirrorMe: mirrorMe, mirrorTutorial: mirrorTutorial)
        }
        .sheet(isPresented: $showAnalysis, onDismiss: {
            report = take.analysisReport
        }) {
            AnalysisView(
                project: project,
                take: take,
                tutorialMirrored: mirrorTutorial,
                takeMirrored: mirrorMe,
                onJump: { time in
                    showAnalysis = false   // show the moment, not the sheet
                    playback.seek(to: time)
                },
                onCoach: { findings, index in
                    showAnalysis = false
                    report = take.analysisReport
                    enterCoach(findings, at: index)
                }
            )
            // Full height: issues are shown on the video itself (coach mode),
            // so the sheet doesn't need to share the screen. (Half-height sheets
            // float with inset rounded corners on iOS 26+, which looked misaligned.)
            .presentationDetents([.large])
        }
    }

    /// Starts playing from the range start once everything is loaded.
    private func startAutoPlayIfNeeded() {
        guard autoPlay, !didAutoPlay, !Task.isCancelled,
              playback.isReady, !playback.isPlaying else { return }
        didAutoPlay = true
        SyncedPlayback.activateAudioSession()
        playback.play()
    }

    // MARK: - Videos (full-bleed background) + controls (inside the safe area)

    /// The videos behind, the controls in front. Tapping the video hides/shows
    /// the controls (the coach card and the ghost gestures don't).
    private func videoRegion(landscape: Bool, insets: EdgeInsets) -> some View {
        // Where the videos may reach into the safe area. In portrait the
        // controls bar below them keeps its own black background.
        let edges: Edge.Set = (landscape || !controlsVisible) ? .all : [.top, .horizontal]
        return ZStack {
            Color.clear
                .ignoresSafeArea(.container, edges: edges)
                .contentShape(Rectangle())
                .onTapGesture {
                    controlsVisible.toggle()
                }
                .simultaneousGesture(ghostPanGesture, including: isSideBySide ? .subviews : .all)
                .simultaneousGesture(ghostZoomGesture, including: isSideBySide ? .subviews : .all)

            controlsOverlay(landscape: landscape)
        }
        .background {
            videoArea(landscape: landscape, insets: insets)
                .ignoresSafeArea(.container, edges: edges)
        }
    }

    /// Where the two pictures go (in the full-bleed area).
    private static func paneRects(size: CGSize, landscape: Bool, sideBySide: Bool)
        -> (you: CGRect, tutorial: CGRect) {
        let full = CGRect(origin: .zero, size: size)
        guard sideBySide else { return (full, full) }
        let gap: CGFloat = 2
        if landscape {
            let width = (size.width - gap) / 2
            return (CGRect(x: 0, y: 0, width: width, height: size.height),
                    CGRect(x: width + gap, y: 0, width: width, height: size.height))
        } else {
            let height = (size.height - gap) / 2
            return (CGRect(x: 0, y: 0, width: size.width, height: height),
                    CGRect(x: 0, y: height + gap, width: size.width, height: height))
        }
    }

    /// Always the same two video views (only their frames change), so rotating
    /// or switching to ghost never restarts anything.
    private func videoArea(landscape: Bool, insets: EdgeInsets) -> some View {
        GeometryReader { geo in
            let size = geo.size
            let rects = Self.paneRects(size: size, landscape: landscape, sideBySide: isSideBySide)

            let auto = autoGhostTransform(container: size)
            let zoom = min(max(ghostZoom * zoomDelta, 0.3), 4)
            let ghostScale: CGFloat = isSideBySide ? 1 : auto.scale * zoom
            let ghostOffset: CGSize = isSideBySide ? .zero : CGSize(
                width: auto.offset.width + ghostPan.width + panDelta.width,
                height: auto.offset.height + ghostPan.height + panDelta.height
            )

            let overlayOn = showsPoseOverlay
            let highlight: Set<Joint> = {
                guard overlayOn, let finding = currentFinding else { return [] }
                return CoachSupport.joints(forBodyPart: finding.bodyPart)
            }()

            ZStack {
                Color.black

                youLayer(rect: rects.you, overlayOn: overlayOn, highlight: highlight)

                tutorialLayer(rect: rects.tutorial, scale: ghostScale, offset: ghostOffset,
                              overlayOn: overlayOn, highlight: highlight)

                if isSideBySide {
                    badge("YOU", origin: badgeOrigin(for: rects.you, insets: insets))
                    badge("TUTORIAL", origin: badgeOrigin(for: rects.tutorial, insets: insets))
                }

                statusOverlay
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .animation(.snappy(duration: 0.3), value: isSideBySide)
        }
        .allowsHitTesting(false)
    }

    private func youLayer(rect: CGRect, overlayOn: Bool, highlight: Set<Joint>) -> some View {
        ZStack {
            youVideo
            if overlayOn {
                poseLayer(pose: coachPoses?.take, mirrored: mirrorMe, color: .white,
                          highlight: highlight, paneSize: rect.size)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }

    private func tutorialLayer(rect: CGRect, scale: CGFloat, offset: CGSize,
                               overlayOn: Bool, highlight: Set<Joint>) -> some View {
        ZStack {
            tutorialVideo
                .opacity(isSideBySide ? 1 : ghostOpacity)
            if overlayOn {
                // The tips name YOUR limbs; if only one video is mirrored, the
                // tutorial's matching limb is on the other side.
                poseLayer(pose: coachPoses?.tutorial, mirrored: mirrorTutorial, color: Theme.loopColor,
                          highlight: mirrorMe == mirrorTutorial ? highlight : CoachSupport.swappedSides(highlight),
                          paneSize: rect.size)
            }
        }
        .frame(width: rect.width, height: rect.height)
        // Ghost alignment: the skeleton rides along with the picture.
        .scaleEffect(scale)
        .offset(offset)
        .position(x: rect.midX, y: rect.midY)
    }

    /// A skeleton drawn exactly over an aspect-fit video inside a pane.
    @ViewBuilder
    private func poseLayer(pose: PoseSample?, mirrored: Bool, color: Color,
                           highlight: Set<Joint>, paneSize: CGSize) -> some View {
        if let pose, pose.aspect > 0, paneSize.width > 0, paneSize.height > 0 {
            let aspect = CGFloat(pose.aspect)
            let fit = CoachSupport.aspectFitRect(aspect: aspect, in: paneSize)
            PoseOverlay(pose: pose, videoAspect: aspect, mirrored: mirrored,
                        color: color, highlight: highlight)
                .frame(width: fit.width, height: fit.height)
                .position(x: fit.midX, y: fit.midY)
                .frame(width: paneSize.width, height: paneSize.height)
                .allowsHitTesting(false)
        }
    }

    /// Top-left corner of a pane's badge, kept below the top buttons.
    private func badgeOrigin(for rect: CGRect, insets: EdgeInsets) -> CGPoint {
        let x = max(rect.minX, insets.leading) + 10
        let touchesTop = rect.minY < 1
        let y = touchesTop ? insets.top + (controlsVisible ? 56 : 8) : rect.minY + 10
        return CGPoint(x: x, y: y)
    }

    /// Small translucent capsule ("YOU" / "TUTORIAL").
    private func badge(_ title: String, origin: CGPoint) -> some View {
        Text(title)
            .font(.system(.caption2, design: .rounded).weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.42)))
            .padding(.leading, origin.x)
            .padding(.top, origin.y)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityHidden(true)
    }

    private var youVideo: some View {
        CompareVideoLayer(player: playback.takePlayer)
            .scaleEffect(x: mirrorMe ? -1 : 1, y: 1)
            .opacity(playback.isReady ? 1 : 0)
    }

    private var tutorialVideo: some View {
        CompareVideoLayer(player: playback.tutorialPlayer)
            .scaleEffect(x: mirrorTutorial ? -1 : 1, y: 1)
            .opacity(playback.isReady ? 1 : 0)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if let error = playback.loadError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding()
        } else if !playback.isReady {
            ProgressView()
                .tint(.white)
                .controlSize(.large)
        }
    }

    // MARK: - Controls layer (inside the safe area)

    private func controlsOverlay(landscape: Bool) -> some View {
        VStack(spacing: 8) {
            if controlsVisible {
                topRow(landscape: landscape)
            }
            Spacer(minLength: 0)
            if let finding = currentFinding {
                coachCard(finding, landscape: landscape)
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if landscape && controlsVisible {
                landscapeBar
            }
        }
        .padding(.bottom, 8)
        .animation(.snappy, value: coachActive)
    }

    // MARK: Top row (close, issues, mode, mirror, sync, analyze)

    private func topRow(landscape: Bool) -> some View {
        GlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.round(size: 40))
                .accessibilityLabel("Close")

                if let onRecordAgain {
                    Button {
                        onRecordAgain()
                    } label: {
                        Image(systemName: "record.circle")
                            .foregroundStyle(Color.red)
                    }
                    .buttonStyle(.round(size: 40))
                    .accessibilityLabel("Record again")
                }

                if let count = fixCount, !coachActive {
                    fixCapsule(count, compact: onRecordAgain != nil && !landscape)
                }

                Spacer(minLength: 0)

                if landscape {
                    // Plenty of room in landscape: the mode switch lives up here.
                    modePicker
                        .frame(width: 220)
                }

                mirrorMenu

                Button {
                    showSync = true
                } label: {
                    Image(systemName: "timer")
                }
                .buttonStyle(.round(size: 40, isOn: abs(playback.nudge) > 0.0005, tint: Theme.loopColor))
                .accessibilityLabel("Sync")
                .popover(isPresented: $showSync) {
                    CompareSyncPanel(playback: playback) {
                        // Close the popover first, then open the analysis sheet.
                        showSync = false
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 400_000_000)
                            showAnalysis = true
                        }
                    }
                    .presentationCompactAdaptation(.popover)
                    .preferredColorScheme(.dark)
                }

                Button {
                    playback.pause()
                    showExport = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.round(size: 40))
                .accessibilityLabel("Save video")

                Button {
                    showAnalysis = true
                } label: {
                    Image(systemName: "sparkles")
                }
                .buttonStyle(.round(size: 40, isOn: true))
                .accessibilityLabel("Analyze")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    /// "3 things to fix": opens coach mode at the first issue.
    private func fixCapsule(_ count: Int, compact: Bool = false) -> some View {
        Button {
            showIssues()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                Text(compact ? "\(count) to fix"
                     : (count == 1 ? "1 thing to fix" : "\(count) things to fix"))
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(Color.black)
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(Capsule().fill(Theme.accent))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!playback.isReady)
        .opacity(playback.isReady ? 1 : 0.5)
        .accessibilityLabel("Show issues")
    }

    /// Mirror switches live in a menu to save space.
    private var mirrorMenu: some View {
        Menu {
            Toggle("Mirror me", isOn: $mirrorMe)
            Toggle("Mirror tutorial", isOn: $mirrorTutorial)
        } label: {
            Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 40, height: 40)
                .glassSurface(Circle(), interactive: true)
                .contentShape(Circle())
        }
        .accessibilityLabel("Mirror options")
    }

    /// "Ghost" | "Side by side".
    private var modePicker: some View {
        PillPicker<Bool>(
            options: [
                PillPicker<Bool>.Option(value: false, title: "Ghost",
                                        accessibilityLabel: "Ghost"),
                PillPicker<Bool>.Option(value: true, title: "Side by side",
                                        accessibilityLabel: "Side by side")
            ],
            selection: isSideBySide,
            onSelect: { newValue in
                withAnimation(.snappy) { isSideBySide = newValue }
            }
        )
    }

    // MARK: Bottom controls

    private var portraitBar: some View {
        GlassGroup(spacing: 10) {
            VStack(spacing: 12) {
                modePicker
                if !isSideBySide {
                    ghostRow
                }
                timelineBlock
                transportRow(compact: false)
                speedPicker
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        // Black all the way down behind the home indicator.
        .background(Color.black.ignoresSafeArea(.container, edges: .bottom))
    }

    private var landscapeBar: some View {
        GlassGroup(spacing: 10) {
            VStack(spacing: 6) {
                if !isSideBySide {
                    ghostRow
                }
                timelineBlock
                HStack(spacing: 16) {
                    transportRow(compact: true)
                    speedPicker
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background {
                let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
                shape
                    .fill(.ultraThinMaterial)
                    .overlay(shape.fill(Color.black.opacity(0.3)))
                    .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
            }
        }
        .frame(maxWidth: 640)
        .padding(.horizontal, 12)
    }

    // MARK: - Control pieces

    /// [Back one frame] [Play / Pause] [Forward one frame] [Loop]
    private func transportRow(compact: Bool) -> some View {
        let side: CGFloat = compact ? 40 : 48
        let playSize: CGFloat = compact ? 52 : 60
        let loopSize: CGFloat = compact ? 40 : 44
        return HStack(spacing: compact ? 12 : 20) {
            Button {
                playback.stepFrames(-1)
            } label: {
                Image(systemName: "backward.frame.fill")
            }
            .buttonStyle(.round(size: side))
            .buttonRepeatBehavior(.enabled)
            .disabled(!playback.isReady)
            .accessibilityLabel("Back one frame")

            Button {
                playback.togglePlayPause()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.round(size: playSize, prominent: true))
            .disabled(!playback.isReady)
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

            Button {
                playback.stepFrames(1)
            } label: {
                Image(systemName: "forward.frame.fill")
            }
            .buttonStyle(.round(size: side))
            .buttonRepeatBehavior(.enabled)
            .disabled(!playback.isReady)
            .accessibilityLabel("Forward one frame")

            Button {
                playback.isLooping.toggle()
            } label: {
                Image(systemName: "repeat")
            }
            .buttonStyle(.round(size: loopSize, isOn: playback.isLooping, tint: Theme.loopColor))
            .accessibilityLabel(playback.isLooping ? "Loop on" : "Loop off")
        }
        .animation(.snappy, value: playback.isPlaying)
        .animation(.snappy, value: playback.isLooping)
        .opacity(playback.isReady ? 1 : 0.45)
    }

    private var speedPicker: some View {
        let options = SyncedPlayback.speeds.map { speed -> PillPicker<Float>.Option in
            let title = SyncedPlayback.speedLabel(Double(speed))
            return PillPicker<Float>.Option(
                value: speed,
                title: title,
                accessibilityLabel: "Speed \(title)"
            )
        }
        return PillPicker<Float>(
            options: options,
            selection: playback.rate,
            onSelect: { speed in
                // Picking a speed while paused just starts playing at it.
                let wasPlaying = playback.isPlaying
                playback.setRate(speed)
                if !wasPlaying && playback.isReady {
                    playback.play()
                }
            }
        )
    }

    // MARK: - Timeline

    private var shownTime: Double {
        isScrubbing ? scrubTime : playback.currentTime
    }

    private var timelineBlock: some View {
        VStack(spacing: 2) {
            let markers = markerFindings
            if !markers.isEmpty {
                CompareFindingMarkers(
                    times: markers.map(\.time),
                    labels: markers.map { "Issue at \(formatTime($0.time)): \($0.bodyPart)" },
                    selected: markers.firstIndex { $0.id == currentFinding?.id },
                    lower: playback.range.lowerBound,
                    upper: playback.range.upperBound,
                    onTap: { index in
                        enterCoach(markers, at: index)
                    }
                )
            }
            CompareTimelineBar(
                value: shownTime,
                lower: playback.range.lowerBound,
                upper: playback.range.upperBound,
                isDragging: isScrubbing,
                onScrub: { scrubChanged($0) },
                onScrubEnd: { scrubEnded($0) },
                onNudge: { playback.seek(to: shownTime + $0) }
            )
            timeLabels
        }
        .disabled(!playback.isReady)
        .opacity(playback.isReady ? 1 : 0.45)
    }

    private var timeLabels: some View {
        let remaining = max(playback.range.upperBound - shownTime, 0)
        return ZStack {
            HStack {
                Text(formatTime(shownTime))
                Spacer(minLength: 8)
                Text(formatTime(-remaining))
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(Theme.secondaryText)
            .lineLimit(1)

            if let label = countLabel {
                Text(label)
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

    private func scrubChanged(_ time: Double) {
        if !isScrubbing {
            // Finger down: remember if we were playing, then pause.
            wasPlayingBeforeScrub = playback.isPlaying
            isScrubbing = true
            cancelReplay()
            playback.pause()
        }
        scrubTime = time
        playback.seek(to: time)   // live preview while dragging
    }

    private func scrubEnded(_ time: Double) {
        // Finger up: land exactly where the knob is.
        playback.seek(to: time)
        isScrubbing = false
        if wasPlayingBeforeScrub {
            playback.play()
        }
    }

    /// "8-count 5 · 3" when the project has a tempo.
    private var countLabel: String? {
        let grid = CountGrid(bpm: project.bpm, offset: project.offset, duration: playback.tutorialDuration)
        guard grid.isValid,
              let index = grid.index(at: shownTime),
              let beat = grid.beat(at: shownTime) else { return nil }
        return "8-count \(index + 1) · \(beat)"
    }

    // MARK: - Ghost mode

    /// Opacity slider, "Auto-align" and a tiny status (ghost mode only).
    private var ghostRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .accessibilityHidden(true)
            Slider(value: $ghostOpacity, in: 0.2...0.8)
                .tint(Theme.loopColor)
                .accessibilityLabel("Ghost opacity")
            if let status = ghostStatusText {
                Text(status)
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
            }
            Button {
                autoAlign()
            } label: {
                Image(systemName: "wand.and.stars")
            }
            .buttonStyle(.round(size: 36))
            .accessibilityLabel("Auto-align ghost")
        }
        .padding(.horizontal, 4)
        .frame(height: 38)
        .animation(.snappy, value: alignState)
    }

    private var ghostStatusText: String? {
        switch alignState {
        case .aligning: return "Aligning…"
        case .failed: return "Not aligned"
        case .idle, .done: return nil
        }
    }

    private var alignTrigger: CompareAlignTrigger {
        CompareAlignTrigger(ready: playback.isReady, ghost: !isSideBySide, nonce: alignNonce)
    }

    /// Drag the ghost to move it.
    private var ghostPanGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .updating($panDelta) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                ghostPan = CGSize(width: ghostPan.width + value.translation.width,
                                  height: ghostPan.height + value.translation.height)
            }
    }

    /// Pinch to resize the ghost.
    private var ghostZoomGesture: some Gesture {
        MagnifyGesture()
            .updating($zoomDelta) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                ghostZoom = min(max(ghostZoom * value.magnification, 0.3), 4)
            }
    }

    /// Scale + offset that puts the tutorial dancer on top of you.
    private func autoGhostTransform(container: CGSize) -> (scale: CGFloat, offset: CGSize) {
        guard alignState == .done,
              let tutorialBox, let takeBox, let tutorialAspect, let takeAspect,
              container.width > 0, container.height > 0 else {
            return (1, .zero)
        }
        return CoachSupport.ghostTransform(
            tutorialBox: tutorialBox, tutorialAspect: tutorialAspect, tutorialMirrored: mirrorTutorial,
            takeBox: takeBox, takeAspect: takeAspect, takeMirrored: mirrorMe,
            container: container
        )
    }

    /// Back to the automatic alignment (and try again if it failed).
    private func autoAlign() {
        withAnimation(.snappy) {
            ghostPan = .zero
            ghostZoom = 1
        }
        if alignState != .done && alignState != .aligning {
            alignState = .idle
            alignNonce += 1
        }
    }

    /// Finds both bodies once (over the part of the dance your take covers).
    private func alignGhostIfNeeded() async {
        guard playback.isReady, !isSideBySide else { return }
        // A cancelled earlier run may still be winding down: let it finish first.
        while alignState == .aligning && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !Task.isCancelled, playback.isReady, !isSideBySide else { return }
        guard alignState == .idle || alignState == .failed else { return }
        guard let tutorialURL = project.videoURL else {
            alignState = .failed
            return
        }
        alignState = .aligning

        let range = playback.range
        let timing = take.timing
        let takeURL = take.videoURL
        let takeFrom = max(timing.takeTime(forTutorialTime: range.lowerBound), 0)
        let takeTo = max(timing.takeTime(forTutorialTime: range.upperBound), takeFrom)

        async let tutorialBodyBox = CoachSupport.averageBodyBox(
            url: tutorialURL, from: range.lowerBound, to: range.upperBound)
        async let takeBodyBox = CoachSupport.averageBodyBox(
            url: takeURL, from: takeFrom, to: takeTo)
        async let tutorialShape = Self.videoAspect(of: tutorialURL)
        async let takeShape = Self.videoAspect(of: takeURL)

        let tBox = await tutorialBodyBox
        let kBox = await takeBodyBox
        let tAspect = await tutorialShape
        let kAspect = await takeShape

        if Task.isCancelled {
            alignState = .idle
            return
        }
        if let tBox, let kBox, let tAspect, let kAspect {
            tutorialBox = tBox
            takeBox = kBox
            tutorialAspect = tAspect
            takeAspect = kAspect
            alignState = .done
        } else {
            // No body found: the ghost simply stays centered.
            alignState = .failed
        }
    }

    /// Display width / height of a video (rotation taken into account).
    nonisolated private static func videoAspect(of url: URL) async -> CGFloat? {
        let asset = AVURLAsset(url: url)
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let shown = CGRect(origin: .zero, size: size).applying(transform)
            let width = abs(shown.width)
            let height = abs(shown.height)
            guard width > 0, height > 0 else { return nil }
            return width / height
        } catch {
            return nil
        }
    }

    // MARK: - Coach mode

    private var currentFinding: AnalysisReport.Finding? {
        coachFindings.indices.contains(coachIndex) ? coachFindings[coachIndex] : nil
    }

    private var coachActive: Bool { currentFinding != nil }

    private var coachKey: CompareCoachKey {
        CompareCoachKey(finding: currentFinding?.id, index: coachIndex)
    }

    /// Skeletons are shown only while the picture is parked on the moment.
    private var showsPoseOverlay: Bool {
        guard let finding = currentFinding, coachPoses != nil,
              !playback.isPlaying, !isReplaying else { return false }
        return abs(playback.currentTime - finding.time) < 0.3
    }

    /// Every issue of the saved analysis that lies in the take, by time.
    private var markerFindings: [AnalysisReport.Finding] {
        guard let report else { return [] }
        var seenIDs = Set<UUID>()
        var seenKeys = Set<String>()
        var result: [AnalysisReport.Finding] = []
        let all = report.topFindings + report.segments.flatMap { $0.findings }
        for finding in all {
            let key = "\(finding.bodyPart)|\(finding.message)|\(Int((finding.time * 10).rounded()))"
            guard seenIDs.insert(finding.id).inserted, seenKeys.insert(key).inserted else { continue }
            guard playback.range.contains(finding.time) else { continue }
            result.append(finding)
        }
        return result.sorted { $0.time < $1.time }
    }

    /// How many things the accent capsule says need fixing (nil = no report).
    private var fixCount: Int? {
        guard let report else { return nil }
        let count = report.topFindings.isEmpty ? markerFindings.count : report.topFindings.count
        return count > 0 ? count : nil
    }

    private func showIssues() {
        guard let report else { return }
        let list = report.topFindings.isEmpty ? markerFindings : report.topFindings
        enterCoach(list, at: 0)
    }

    private func enterCoach(_ findings: [AnalysisReport.Finding], at index: Int) {
        guard !findings.isEmpty else { return }
        cancelReplay()
        playback.pause()
        let safe = min(max(index, 0), findings.count - 1)
        coachFindings = findings
        coachIndex = safe
        coachPoses = nil
        controlsVisible = true
        playback.seek(to: findings[safe].time)
    }

    private func stepCoach(_ delta: Int) {
        let next = coachIndex + delta
        guard coachFindings.indices.contains(next) else { return }
        cancelReplay()
        playback.pause()
        coachIndex = next
        coachPoses = nil
        playback.seek(to: coachFindings[next].time)
    }

    private func closeCoach() {
        cancelReplay()
        coachFindings = []
        coachIndex = 0
        coachPoses = nil
    }

    /// Finds both skeletons for the current issue.
    private func loadCoachPoses() async {
        guard let finding = currentFinding, let tutorialURL = project.videoURL else {
            coachPoses = nil
            return
        }
        let takeTime = max(take.timing.takeTime(forTutorialTime: finding.time), 0)
        let result = await CoachSupport.poses(
            tutorialURL: tutorialURL, tutorialTime: finding.time,
            takeURL: take.videoURL, takeTime: takeTime
        )
        guard !Task.isCancelled, currentFinding?.id == finding.id else { return }
        coachPoses = result
    }

    /// Plays 3 seconds around the moment at half speed, then parks on it again.
    private func replayMoment() {
        guard let finding = currentFinding, playback.isReady else { return }
        cancelReplay()
        let range = playback.range
        let start = min(max(finding.time - 1.5, range.lowerBound), range.upperBound)
        let end = min(start + 3, range.upperBound)

        replayRestore = CompareReplayRestore(rate: playback.rate, loop: playback.isLooping)
        isReplaying = true
        playback.pause()
        playback.isLooping = false
        playback.setRate(0.5)
        playback.seek(to: start)
        playback.play()

        replayTask = Task { @MainActor in
            let began = CACurrentMediaTime()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 40_000_000)
                if !playback.isPlaying { break }
                if playback.currentTime >= end - 0.02 { break }
                // Safety net: 3 s at half speed is 6 s.
                if CACurrentMediaTime() - began > 9 { break }
            }
            guard !Task.isCancelled else { return }
            playback.pause()
            endReplay()
            if let finding = currentFinding {
                playback.seek(to: finding.time)
            }
        }
    }

    /// Stops a running replay (if any) and restores speed and loop.
    private func cancelReplay() {
        replayTask?.cancel()
        replayTask = nil
        endReplay()
    }

    private func endReplay() {
        if let restore = replayRestore {
            playback.setRate(restore.rate)
            playback.isLooping = restore.loop
            replayRestore = nil
        }
        isReplaying = false
    }

    // MARK: Coach card

    private func coachCard(_ finding: AnalysisReport.Finding, landscape: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return GlassGroup(spacing: 8) {
            Group {
                if landscape {
                    HStack(spacing: 12) {
                        coachText(finding)
                        Spacer(minLength: 8)
                        coachControls
                        closeCoachButton
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 8) {
                            coachText(finding)
                            Spacer(minLength: 0)
                            closeCoachButton
                        }
                        coachControls
                    }
                }
            }
            .padding(landscape ? 10 : 12)
            .background(shape.fill(Color.black.opacity(0.3)))
            .glassSurface(shape, fallback: Theme.surface.opacity(0.94))
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
            .contentShape(shape)
            // Taps on the card must not hide the controls.
            .onTapGesture {}
        }
        .frame(maxWidth: landscape ? 700 : .infinity)
    }

    private func coachText(_ finding: AnalysisReport.Finding) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(finding.bodyPart.uppercased())
                .font(.system(.caption2, design: .rounded).weight(.bold))
                .tracking(1.2)
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
            Text(finding.message)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(Color.white)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
            Text(coachWhen(finding))
                .font(.system(.caption, design: .rounded).weight(.medium))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func coachWhen(_ finding: AnalysisReport.Finding) -> String {
        if let eightCount = finding.eightCount, let beat = finding.beat {
            return "8-count \(eightCount + 1) · count \(beat)"
        }
        if let eightCount = finding.eightCount {
            return "8-count \(eightCount + 1)"
        }
        return formatTime(finding.time)
    }

    /// "1 / 5"  ‹  ›  [Replay]
    private var coachControls: some View {
        HStack(spacing: 8) {
            Text("\(coachIndex + 1) / \(coachFindings.count)")
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Color.white)
                .padding(.trailing, 4)
                .accessibilityLabel("Issue \(coachIndex + 1) of \(coachFindings.count)")

            Spacer(minLength: 0)

            Button {
                stepCoach(-1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.round(size: 40))
            .disabled(coachIndex <= 0)
            .opacity(coachIndex <= 0 ? 0.4 : 1)
            .accessibilityLabel("Previous issue")

            Button {
                stepCoach(1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.round(size: 40))
            .disabled(coachIndex >= coachFindings.count - 1)
            .opacity(coachIndex >= coachFindings.count - 1 ? 0.4 : 1)
            .accessibilityLabel("Next issue")

            Button {
                if isReplaying {
                    cancelReplay()
                    playback.pause()
                    if let finding = currentFinding {
                        playback.seek(to: finding.time)
                    }
                } else {
                    replayMoment()
                }
            } label: {
                Image(systemName: "gobackward")
            }
            .buttonStyle(.round(size: 40, isOn: isReplaying, tint: Theme.loopColor))
            .disabled(!playback.isReady)
            .accessibilityLabel("Replay this moment")
        }
    }

    private var closeCoachButton: some View {
        Button {
            closeCoach()
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(.round(size: 36))
        .accessibilityLabel("Close coach")
    }
}

// MARK: - Small helper types

private enum CompareGhostAlignState: Equatable {
    case idle, aligning, done, failed
}

/// Changes whenever the ghost alignment should be (re)started.
private struct CompareAlignTrigger: Hashable {
    var ready: Bool
    var ghost: Bool
    var nonce: Int
}

/// Changes whenever the skeletons have to be loaded again.
private struct CompareCoachKey: Hashable {
    var finding: UUID?
    var index: Int
}

/// Speed and loop setting to bring back after "Replay this moment".
private struct CompareReplayRestore {
    var rate: Float
    var loop: Bool
}

// MARK: - Finding markers (red dots above the timeline)

/// A thin row of small red dots, one per issue, lined up with the timeline
/// track below it. Tap a dot to open coach mode at that issue.
private struct CompareFindingMarkers: View {
    let times: [Double]
    let labels: [String]
    let selected: Int?
    let lower: Double
    let upper: Double
    let onTap: (Int) -> Void

    private let knobSize: CGFloat = 14

    private var span: Double { max(upper - lower, 0.0001) }

    var body: some View {
        GeometryReader { geo in
            let usable = max(geo.size.width - knobSize, 1)
            ForEach(Array(times.enumerated()), id: \.offset) { index, time in
                let fraction = CGFloat(min(max((time - lower) / span, 0), 1))
                let isSelected = selected == index
                Button {
                    onTap(index)
                } label: {
                    Circle()
                        .fill(Color.red)
                        .frame(width: isSelected ? 11 : 7, height: isSelected ? 11 : 7)
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: isSelected ? 1.5 : 0))
                        .frame(width: 24, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(labels.indices.contains(index) ? labels[index] : "Issue")
                .position(x: knobSize / 2 + usable * fraction, y: geo.size.height / 2)
            }
        }
        .frame(height: 20)
    }
}

// MARK: - Sync popover

/// Small panel to nudge your video earlier/later and to start the analysis.
@MainActor
private struct CompareSyncPanel: View {
    let playback: SyncedPlayback
    let onAnalyze: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Sync your video")
                    .font(.system(.headline, design: .rounded))

                Text("If your moves look early or late even though you danced on the beat, nudge your video. Looks late? Tap +. Looks early? Tap −.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("Nudge")
                        .foregroundStyle(Theme.secondaryText)
                    Spacer()
                    Text(nudgeText)
                        .font(.system(.body, design: .monospaced).weight(.bold))
                        .monospacedDigit()
                }

                GlassGroup(spacing: 8) {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            nudgeButton("−0.1 s", delta: -0.1)
                            nudgeButton("+0.1 s", delta: 0.1)
                        }
                        HStack(spacing: 8) {
                            nudgeButton("−1 frame", delta: -1.0 / SyncedPlayback.stepFPS)
                            nudgeButton("+1 frame", delta: 1.0 / SyncedPlayback.stepFPS)
                        }
                        HStack(spacing: 8) {
                            Button {
                                playback.applyNudge(-playback.nudge)
                            } label: {
                                Label("Reset", systemImage: "arrow.counterclockwise")
                            }
                            .buttonStyle(CompareCapsuleButtonStyle())
                            .disabled(abs(playback.nudge) < 0.0005)
                            .opacity(abs(playback.nudge) < 0.0005 ? 0.4 : 1)

                            Button(action: onAnalyze) {
                                Label("Analyze", systemImage: "sparkles")
                            }
                            .buttonStyle(CompareCapsuleButtonStyle(prominent: true))
                        }
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 340, height: 340)
    }

    private var nudgeText: String {
        let frames = playback.nudge * SyncedPlayback.stepFPS
        return String(format: "%+.2f s  (%+.1f fr)", playback.nudge, frames)
    }

    private func nudgeButton(_ title: String, delta: Double) -> some View {
        Button {
            playback.applyNudge(delta)
        } label: {
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .buttonStyle(CompareCapsuleButtonStyle())
    }
}

/// Capsule button for the sync panel: glass, or solid accent when `prominent`.
private struct CompareCapsuleButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .foregroundStyle(prominent ? Color.black : Color.white)
            .frame(maxWidth: .infinity, minHeight: Theme.controlHeight)
            .background {
                if prominent {
                    Capsule().fill(Theme.accent)
                }
            }
            .modifier(CompareCapsuleGlass(prominent: prominent))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

private struct CompareCapsuleGlass: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if prominent {
            content
        } else {
            content.glassSurface(Capsule(), interactive: true, fallback: Theme.surfaceRaised)
        }
    }
}

// MARK: - Timeline scrubber

/// A slim custom scrubber: 4 pt track, accent fill, 14 pt knob, and a 32 pt
/// tall hit area where you can tap or drag to seek. `lower...upper` is the
/// part of the tutorial that your take covers.
private struct CompareTimelineBar: View {
    let value: Double
    let lower: Double
    let upper: Double
    let isDragging: Bool
    let onScrub: (Double) -> Void
    let onScrubEnd: (Double) -> Void
    let onNudge: (Double) -> Void

    private let knobSize: CGFloat = 14
    private let trackHeight: CGFloat = 4

    private var span: Double { max(upper - lower, 0.0001) }

    var body: some View {
        GeometryReader { geo in
            let inset = knobSize / 2
            let usable = max(geo.size.width - knobSize, 1)
            let x = inset + usable * fraction(of: value)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.15))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(Theme.accent)
                    .frame(width: x, height: trackHeight)

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
        .accessibilityLabel("Position")
        .accessibilityValue(formatTime(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onNudge(1)
            case .decrement: onNudge(-1)
            @unknown default: break
            }
        }
    }

    private func fraction(of seconds: Double) -> CGFloat {
        guard seconds.isFinite else { return 0 }
        return CGFloat(min(max((seconds - lower) / span, 0), 1))
    }

    private func time(atX x: CGFloat, inset: CGFloat, usable: CGFloat) -> Double {
        let f = min(max((x - inset) / usable, 0), 1)
        return lower + Double(f) * span
    }
}

// MARK: - Video layer

/// Shows an `AVPlayer` aspect-fit. (Named differently from `VideoSurface`'s
/// private `PlayerLayerView` on purpose.)
@MainActor
private struct CompareVideoLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> CompareLayerHostView {
        let view = CompareLayerHostView()
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: CompareLayerHostView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

/// A UIView whose own layer *is* an AVPlayerLayer.
@MainActor
private final class CompareLayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // Safe: `layerClass` above guarantees the layer type.
        layer as! AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Clear: the tutorial can then be a see-through ghost (the screen
        // behind the videos is black anyway).
        backgroundColor = .clear
        playerLayer.videoGravity = .resizeAspect
        // Taps go to SwiftUI (tap to hide/show the controls).
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}
