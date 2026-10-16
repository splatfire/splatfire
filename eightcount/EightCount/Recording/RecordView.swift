import SwiftUI
import SwiftData
import AVFoundation
import CoreMedia
import UIKit

/// The recording screen: the tutorial plays (with its music) while the front
/// camera films you dancing. Afterwards you can jump to the compare screen.
///
/// Present it with `.fullScreenCover`. It has its own Close (X) button.
@MainActor
struct RecordView: View {
    let project: Project
    /// Tutorial time (s) to start from.
    let startTime: Double
    /// Tutorial time (s) at which recording stops by itself (nil = to the end / Stop).
    let endTime: Double?
    /// Tutorial speed while recording (0.25 ... 1).
    let rate: Double
    /// Show the tutorial flipped, like a mirror.
    let tutorialMirrored: Bool
    /// Start with the tutorial hidden (memory test).
    let startHidden: Bool
    /// Called with nil when the screen is closed without a take (X, "Done",
    /// discarded). A saved take is reviewed right here (instant replay), and
    /// closing that review dismisses the cover by itself, so this is not
    /// called with a take any more (the parameter stays for the call site).
    let onFinished: (Take?) -> Void

    @Environment(\.modelContext) private var modelContext

    /// Does all the work (camera, tutorial player, record flow).
    @State private var model = RecordSessionModel()
    @State private var layout: RecordLayout = .ghost
    @State private var ghostOpacity = 0.45
    @State private var showDiscardDialog = false
    /// Identifies this screen to the Apple Watch remote (which pauses while recording).
    @State private var watchID = UUID()
    /// Beeps with the 3-2-1 (also read by the record flow from UserDefaults).
    @AppStorage("countdownSound") private var countdownSound = true
    /// Memory test: the tutorial is hidden (its music still plays) and only
    /// the count is shown. The take is marked as a memory test.
    @State private var hideTutorial = false
    /// The memory-test take whose forgotten 8-counts you're marking.
    @State private var markingTake: MemoryMarkTarget?

    init(project: Project, startTime: Double, endTime: Double?, rate: Double,
         tutorialMirrored: Bool, startHidden: Bool = false, onFinished: @escaping (Take?) -> Void) {
        self.project = project
        self.startTime = max(startTime, 0)
        self.endTime = endTime
        self.rate = min(max(rate, 0.25), 1)
        self.tutorialMirrored = tutorialMirrored
        self.startHidden = startHidden
        self.onFinished = onFinished
        _hideTutorial = State(initialValue: startHidden)
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let take = model.reviewTake {
                // Instant replay of the take that was just saved. Its own
                // Close dismisses this whole cover.
                CompareView(
                    project: project,
                    take: take,
                    tutorialMirrored: tutorialMirrored,
                    autoPlay: true,
                    onRecordAgain: { recordAgainFromReview() }
                )
                .transition(.opacity)
            } else if model.recorder.authorization == .denied || model.recorder.authorization == .restricted {
                permissionDeniedView
            } else {
                recordingScreen
            }
        }
        .statusBarHidden()
        .onAppear {
            OrientationLock.allowLandscape()
            UIApplication.shared.isIdleTimerDisabled = true
            WatchRemoteHandlers.attachBlocked(id: watchID, title: project.title,
                                              message: "Recording – use your iPhone.")
        }
        .task {
            model.setUp(project: project, startTime: startTime, endTime: endTime, rate: rate,
                        context: modelContext, onFinished: onFinished)
            await model.begin()
        }
        .onDisappear {
            WatchRemote.shared.detach(id: watchID)
            model.end()
            OrientationLock.portraitOnly()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: hideTutorial, initial: true) { _, hidden in
            model.memoryTest = hidden
        }
        // A memory test was just saved: ask which 8-counts you forgot.
        .onChange(of: model.reviewTake?.id) { _, _ in
            if let take = model.reviewTake, take.memoryTest,
               CountGrid.unbounded(bpm: project.bpm, offset: project.offset).isValid {
                markingTake = MemoryMarkTarget(take: take)
            }
        }
        .sheet(item: $markingTake) { target in
            MemoryResultSheet(project: project, take: target.take)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .onChange(of: model.recorder.errorMessage) { _, newValue in
            if let newValue { model.errorMessage = newValue }
        }
        .alert("Something went wrong", isPresented: alertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog("Stop and discard this recording?",
                            isPresented: $showDiscardDialog,
                            titleVisibility: .visible) {
            Button("Discard recording", role: .destructive) { model.discardAndClose() }
            Button("Keep recording", role: .cancel) {}
        }
        .sensoryFeedback(trigger: model.phase) { _, newPhase in
            switch newPhase {
            case .countdown: return .start
            case .finishing: return .stop
            case .saved: return .success
            default: return nil
            }
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    // MARK: - Main screen

    private var recordingScreen: some View {
        // This outer reader RESPECTS the safe area (no ignoresSafeArea), so
        // `safeAreaInsets` are the real notch / Dynamic Island / home
        // indicator insets. Only the pictures behind (mediaLayer) go
        // full-bleed; every button, chip and panel stays inside the safe area.
        GeometryReader { outer in
            ZStack {
                mediaLayer(insets: outer.safeAreaInsets)
                controlsLayer
                countdownOverlay
                cameraStatus
            }
            .frame(width: outer.size.width, height: outer.size.height)
        }
        .animation(.snappy, value: model.phase)
        // Coming back from the review: CompareView's onDisappear (portrait
        // lock) may run after our own call, so allow landscape again here.
        .onAppear {
            OrientationLock.allowLandscape()
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }

    // MARK: Camera + tutorial pictures

    /// Where the two pictures go on screen.
    private struct TileRects {
        var camera: CGRect
        var tutorial: CGRect
    }

    private static func tileRects(size: CGSize, landscape: Bool, ghost: Bool) -> TileRects {
        let full = CGRect(origin: .zero, size: size)
        if ghost {
            // Ghost: both pictures fill the whole screen, tutorial on top.
            return TileRects(camera: full, tutorial: full)
        }
        let gap: CGFloat = 2
        if landscape {
            // Camera left, tutorial right.
            let width = (size.width - gap) / 2
            return TileRects(
                camera: CGRect(x: 0, y: 0, width: width, height: size.height),
                tutorial: CGRect(x: width + gap, y: 0, width: width, height: size.height)
            )
        } else {
            // Camera top, tutorial bottom.
            let height = (size.height - gap) / 2
            return TileRects(
                camera: CGRect(x: 0, y: 0, width: size.width, height: height),
                tutorial: CGRect(x: 0, y: height + gap, width: size.width, height: height)
            )
        }
    }

    /// The two pictures. They are always the same two views (only their
    /// frames change), so switching layout never restarts the camera.
    /// - Parameter insets: the REAL safe-area insets, read by the caller
    ///   outside the full-bleed area (inside it they would read as 0).
    private func mediaLayer(insets: EdgeInsets) -> some View {
        GeometryReader { geo in
            let size = geo.size
            let landscape = size.width > size.height
            let ghost = layout == .ghost
            let rects = Self.tileRects(size: size, landscape: landscape, ghost: ghost)
            // Badges sit just below the top buttons.
            let belowButtons = insets.top + 56

            ZStack {
                Color.black

                CameraPreviewView(recorder: model.recorder)
                    .frame(width: rects.camera.width, height: rects.camera.height)
                    .clipped()
                    .overlay(alignment: .topLeading) {
                        if !ghost {
                            badge("YOU", top: belowButtons, leading: insets.leading + 10)
                        }
                    }
                    .position(x: rects.camera.midX, y: rects.camera.midY)

                RecordTutorialLayer(player: model.tutorial.player)
                    .frame(width: rects.tutorial.width, height: rects.tutorial.height)
                    // Only the tutorial picture is flipped, not the badge.
                    .scaleEffect(x: tutorialMirrored ? -1 : 1, y: 1)
                    .opacity(hideTutorial ? 0 : (ghost ? ghostOpacity : 1))
                    .overlay {
                        if let error = model.tutorial.loadError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(Theme.secondaryText)
                                .multilineTextAlignment(.center)
                                .padding()
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if !ghost && !hideTutorial {
                            badge("TUTORIAL", top: landscape ? belowButtons : 10, leading: 10)
                        }
                    }
                    .overlay {
                        if hideTutorial {
                            memoryCount(compact: ghost)
                        }
                    }
                    .position(x: rects.tutorial.midX, y: rects.tutorial.midY)
                    .allowsHitTesting(false)
            }
            .frame(width: size.width, height: size.height)
            .animation(.snappy(duration: 0.3), value: layout)
        }
        .ignoresSafeArea()
    }

    /// Memory test: the count instead of the tutorial picture.
    private func memoryCount(compact: Bool) -> some View {
        TimelineView(.animation(minimumInterval: 0.05)) { _ in
            let grid = CountGrid.unbounded(bpm: project.bpm, offset: project.offset)
            let time = model.tutorial.currentSeconds()
            let playing = model.phase == .recording
            VStack(spacing: 4) {
                Text("MEMORY TEST")
                    .font(.system(.caption2, design: .rounded).weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.accent)
                if grid.isValid && playing, let beat = grid.beat(at: time) {
                    Text("\(beat)")
                        .font(.system(size: compact ? 44 : 72, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.white)
                    Text(grid.index(at: time).map { "8-count \($0 + 1)" } ?? "")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.secondaryText)
                } else if !playing {
                    Text("The tutorial is hidden.\nDance it from memory.")
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.white)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(compact ? 0.45 : 0.75)))
        }
        .accessibilityElement(children: .combine)
    }

    /// Small translucent capsule inside a picture ("YOU" / "TUTORIAL").
    private func badge(_ title: String, top: CGFloat, leading: CGFloat) -> some View {
        Text(title)
            .font(.system(.caption2, design: .rounded).weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.42)))
            .padding(.top, top)
            .padding(.leading, leading)
            .accessibilityHidden(true)
    }

    /// Shown over the camera while it starts, or when it cannot start.
    @ViewBuilder
    private var cameraStatus: some View {
        if model.phase == .idle {
            if let message = model.recorder.errorMessage {
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.white)
                    .padding(16)
                    .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous),
                                  fallback: Theme.surface.opacity(0.9))
                    .padding(32)
            } else if !model.recorder.isRunning {
                ProgressView()
                    .tint(.white)
                    .controlSize(.large)
            }
        }
    }

    // MARK: Controls

    private var controlsLayer: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            bottomControls
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// [Close] ......... "● REC 0:07" ......... [Layout]
    private var topBar: some View {
        GlassGroup(spacing: 10) {
            ZStack {
                HStack(spacing: 10) {
                    Button {
                        closeTapped()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.round(size: 40))
                    .accessibilityLabel("Close")

                    Spacer(minLength: 0)

                    Button {
                        countdownSound.toggle()
                    } label: {
                        Image(systemName: countdownSound ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    }
                    .buttonStyle(.round(size: 40))
                    .accessibilityLabel("Countdown sound")
                    .accessibilityValue(countdownSound ? "On" : "Off")

                    Button {
                        hideTutorial.toggle()
                    } label: {
                        Image(systemName: hideTutorial ? "eye.slash.fill" : "eye")
                    }
                    .buttonStyle(.round(size: 40, isOn: hideTutorial, tint: Theme.accent))
                    .disabled(model.isLayoutLocked)
                    .opacity(model.isLayoutLocked ? 0.4 : 1)
                    .accessibilityLabel("Memory test")
                    .accessibilityValue(hideTutorial ? "On, tutorial hidden" : "Off")

                    Button {
                        layout = (layout == .ghost) ? .sideBySide : .ghost
                    } label: {
                        Image(systemName: layout == .ghost ? "square.on.square" : "rectangle.split.2x1")
                    }
                    .buttonStyle(.round(size: 40, isOn: layout == .ghost, tint: Theme.loopColor))
                    .disabled(model.isLayoutLocked)
                    .opacity(model.isLayoutLocked ? 0.4 : 1)
                    .accessibilityLabel("Layout")
                    .accessibilityValue(layout == .ghost ? "Ghost" : "Side by side")
                }

                if model.isRecordingActive {
                    recChip
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        }
        .animation(.snappy, value: model.isRecordingActive)
    }

    private var recChip: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let elapsed = max(0, CMClockGetTime(CMClockGetHostTimeClock()).seconds - model.recordingStartSeconds)
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                Text("REC \(Self.clock(elapsed))")
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassSurface(Capsule(), tint: Color.red.opacity(0.45), fallback: Color.red.opacity(0.7))
        }
        .accessibilityLabel("Recording")
    }

    private var infoText: String {
        var text = "Starts at \(formatTime(startTime)) · \(Self.rateText(rate))"
        if let endTime, endTime > startTime {
            text += " · until \(formatTime(endTime))"
        }
        return text
    }

    /// Ghost slider (ghost mode only), a small info caption and the record button.
    private var bottomControls: some View {
        VStack(spacing: 12) {
            if layout == .ghost {
                ghostOpacityRow
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            Text(infoText)
                .font(.system(.caption, design: .rounded).weight(.medium))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.75))
                .shadow(color: .black.opacity(0.6), radius: 3)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            recordButton
        }
        .padding(.top, 8)
        .animation(.snappy, value: layout)
    }

    /// Slim slider for how see-through the tutorial "ghost" is.
    private var ghostOpacityRow: some View {
        GlassGroup(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .accessibilityHidden(true)
                Slider(value: $ghostOpacity, in: 0.2...0.8)
                    .tint(Color.white)
                    .accessibilityLabel("Tutorial opacity")
                Text("\(Int((ghostOpacity * 100).rounded()))%")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.white)
                    .frame(width: 40, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .frame(height: 36)
            .glassSurface(Capsule(), fallback: Theme.surface.opacity(0.85))
        }
        .frame(maxWidth: 320)
    }

    /// Classic camera shutter: white ring with a red circle that morphs into
    /// a rounded red square while recording.
    private var recordButton: some View {
        let isStop = model.canStop
        let enabled = model.canStart || model.canStop
        return Button {
            model.recordButtonTapped()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(Color.white, lineWidth: 4)
                    .frame(width: 72, height: 72)
                RoundedRectangle(cornerRadius: isStop ? 8 : 28, style: .continuous)
                    .fill(Color.red)
                    .frame(width: isStop ? 30 : 56, height: isStop ? 30 : 56)
            }
            .frame(width: 80, height: 80)
            .contentShape(Circle())
        }
        .buttonStyle(RecordShutterPressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isStop)
        .accessibilityLabel(isStop ? "Stop recording" : "Start recording")
    }

    // MARK: Countdown

    @ViewBuilder
    private var countdownOverlay: some View {
        if let value = model.countdownValue {
            ZStack {
                Color.black.opacity(0.3).ignoresSafeArea()
                VStack(spacing: 0) {
                    Text("GET READY")
                        .font(.system(value > 0 ? .footnote : .title, design: .rounded).weight(.semibold))
                        .tracking(2)
                        .foregroundStyle(Color.white.opacity(value > 0 ? 0.8 : 1))
                    if value > 0 {
                        Text("\(value)")
                            .font(.system(size: 150, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.white)
                            .id(value)
                            // Appear at once (no fade-in), so the number and its beep land together.
                            .transition(.asymmetric(
                                insertion: .identity,
                                removal: .scale(scale: 0.8).combined(with: .opacity)
                            ))
                    }
                }
                .shadow(color: .black.opacity(0.45), radius: 14)
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(value > 0 ? "Starting in \(value)" : "Get ready")
        } else if model.showGo {
            Text("GO!")
                .font(.system(size: 110, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.accent)
                .shadow(color: .black.opacity(0.45), radius: 14)
                .transition(.scale(scale: 1.3).combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }

    // MARK: Permission denied

    private var permissionDeniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.secondaryText)
                .accessibilityHidden(true)
            Text("Camera access is off")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(Color.white)
            Text("EightCount needs the front camera to film you dancing, so you can compare yourself with the tutorial. Nothing is uploaded and no microphone is used. You can switch the camera on in Settings.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Open Settings", systemImage: "gearshape")
            }
            .buttonStyle(RecordCapsuleButtonStyle(prominent: true))

            Button {
                model.finish(with: nil)
            } label: {
                Text("Close")
            }
            .buttonStyle(RecordCapsuleButtonStyle())
        }
        .padding(24)
        .frame(maxWidth: 420)
    }

    // MARK: - Actions & formatting

    /// "Record again" in the review: back to the camera, ready for a new take.
    private func recordAgainFromReview() {
        model.recordAgain()
        // The compare screen locks portrait when it goes away (a moment
        // later than this call), so allow landscape again after that too.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !model.hasEnded else { return }
            OrientationLock.allowLandscape()
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }

    private func closeTapped() {
        switch model.phase {
        case .starting, .countdown, .recording, .finishing:
            // Closing would lose the recording: ask first.
            showDiscardDialog = true
        case .idle, .saved:
            model.finish(with: nil)
        }
    }

    /// "0:07"
    private static func clock(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "0.5×", "1×"
    private static func rateText(_ rate: Double) -> String {
        String(format: "%g×", rate)
    }
}

/// How the camera and the tutorial are arranged.
private enum RecordLayout {
    case sideBySide
    case ghost
}

/// The shutter button just shrinks a little while pressed.
private struct RecordShutterPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Capsule button: solid accent when `prominent`, otherwise glass.
private struct RecordCapsuleButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(prominent ? Color.black : Color.white)
            .frame(maxWidth: .infinity, minHeight: Theme.controlHeight)
            .background {
                if prominent {
                    Capsule().fill(Theme.accent)
                }
            }
            .modifier(RecordCapsuleGlass(prominent: prominent))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

private struct RecordCapsuleGlass: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if prominent {
            content
        } else {
            content.glassSurface(Capsule(), interactive: true, fallback: Theme.surfaceRaised)
        }
    }
}

// MARK: - The record flow

/// Runs the whole recording: camera, tutorial player, countdown, saving.
///
/// Kept out of the view so closures and timers have a stable object to talk
/// to (a SwiftUI view is a throw-away value).
/// Wraps a take for `.sheet(item:)`.
private struct MemoryMarkTarget: Identifiable {
    let take: Take
    var id: PersistentIdentifier { take.persistentModelID }
}

@MainActor
@Observable
private final class RecordSessionModel {
    enum Phase {
        /// Ready (or waiting for camera / tutorial).
        case idle
        /// Record was tapped; waiting until the camera really writes frames.
        case starting
        /// Camera is recording, the tutorial starts in a few seconds.
        case countdown
        /// Camera is recording and the tutorial plays.
        case recording
        /// Stopped; waiting for the movie file to be finished.
        case finishing
        /// Take saved; the instant replay (review) is shown.
        case saved
    }

    /// The camera starts recording this many seconds BEFORE the tutorial.
    /// (This is saved as the take's `takeOffset`.) Half a second of "GET
    /// READY", then 3 · 2 · 1, one second each.
    nonisolated static let countdownSeconds: Double = 3.5
    /// The "GET READY" moment before the 3. It also gives the iPhone's audio
    /// time to start, so the first beep isn't late or swallowed.
    nonisolated static let readySeconds: Double = 0.5

    /// The top-bar speaker toggle (`@AppStorage("countdownSound")`, default on).
    private static var countdownSoundEnabled: Bool {
        UserDefaults.standard.object(forKey: "countdownSound") as? Bool ?? true
    }

    let recorder = CameraRecorder()
    let tutorial = RecordTutorialPlayer()
    /// The tutorial is hidden: the take is saved as a memory test.
    var memoryTest = false
    /// Beeps of the 3-2-1.
    private let sounds = CountdownSounds()

    private(set) var phase: Phase = .idle
    /// 3, 2, 1 while counting down, otherwise nil.
    private(set) var countdownValue: Int? = nil
    private(set) var showGo = false
    private(set) var savedTake: Take? = nil
    /// Host-clock time (s) when the camera started recording (for "REC 0:07").
    private(set) var recordingStartSeconds: Double = 0
    var errorMessage: String? = nil

    @ObservationIgnored private var project: Project?
    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var onFinished: ((Take?) -> Void)?
    @ObservationIgnored private var startTime: Double = 0
    @ObservationIgnored private var rate: Double = 1
    @ObservationIgnored private var didSetUp = false
    @ObservationIgnored private var didFinish = false
    @ObservationIgnored private var isEnded = false
    @ObservationIgnored private var countdownTask: Task<Void, Never>? = nil
    /// Tutorial time when recording stopped.
    @ObservationIgnored private var tutorialEndSeconds: Double = 0
    /// Delete the file instead of saving it (stopped too early / closed).
    @ObservationIgnored private var discardOnFinish = false

    // MARK: Derived state for the buttons

    var isRecordingActive: Bool {
        phase == .starting || phase == .countdown || phase == .recording
    }
    var canStart: Bool {
        phase == .idle && recorder.isRunning && tutorial.isReady
    }
    var canStop: Bool {
        phase == .countdown || phase == .recording
    }
    /// True once the screen went away.
    var hasEnded: Bool { isEnded }
    /// The saved take while it is being reviewed (instant replay).
    var reviewTake: Take? {
        phase == .saved ? savedTake : nil
    }
    var isLayoutLocked: Bool {
        phase == .starting || phase == .countdown || phase == .finishing
    }

    // MARK: Lifecycle

    func setUp(project: Project, startTime: Double, endTime: Double?, rate: Double,
               context: ModelContext, onFinished: @escaping (Take?) -> Void) {
        guard !didSetUp else { return }
        didSetUp = true
        self.project = project
        self.context = context
        self.onFinished = onFinished
        self.startTime = startTime
        self.rate = rate
        tutorial.onReachedEnd = { [weak self] in
            self?.tutorialReachedEnd()
        }
        tutorial.configure(startTime: startTime, endTime: endTime, rate: Float(rate))
    }

    /// Prepares sound, tutorial and camera.
    func begin() async {
        // Play the tutorial's music even when the silent switch is on.
        // (The camera records no sound, so nothing else needs the audio session.)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)

        sounds.preload()
        tutorial.prepare(url: project?.videoURL)
        await recorder.start()
    }

    /// The screen went away: stop everything. A recording that is still
    /// running is thrown away.
    func end() {
        isEnded = true
        if isRecordingActive || phase == .finishing {
            discardOnFinish = true
            if isRecordingActive { beginFinishing() }
        }
        countdownTask?.cancel()
        countdownTask = nil
        sounds.cancel()
        tutorial.tearDown()
        recorder.stop()
    }

    /// Hands the result to whoever presented this screen (once).
    func finish(with take: Take?) {
        guard !didFinish else { return }
        didFinish = true
        onFinished?(take)
    }

    // MARK: Record / stop

    func recordButtonTapped() {
        switch phase {
        case .idle: startRecordingFlow()
        case .countdown, .recording: stopRecordingTapped()
        default: break
        }
    }

    private func startRecordingFlow() {
        guard canStart else { return }
        let fileName = TakeStore.newTakeFileName()
        let url = VideoStorage.url(forFileName: fileName)

        discardOnFinish = false
        tutorialEndSeconds = startTime
        savedTake = nil
        phase = .starting

        recorder.startRecording(
            to: url,
            onStarted: { [weak self] hostTime in
                self?.recordingStarted(hostTime: hostTime)
            },
            onFinished: { [self] result in
                self.recordingFinished(result, fileName: fileName)
            }
        )
    }

    /// The camera is now really recording. Schedule the tutorial to start
    /// exactly `countdownSeconds` later, using the iPhone's host clock, and
    /// show the 3-2-1.
    ///
    /// Sync note: the recording starts ~3 s before the tutorial, so the take
    /// is saved with `takeOffset = 3`. The real delay is never exactly 3 s,
    /// so the compare screen lets the user fine-tune the sync (`syncNudge`).
    private func recordingStarted(hostTime: CMTime) {
        guard phase == .starting else { return }
        let delay = CMTime(seconds: Self.countdownSeconds, preferredTimescale: 60_000)
        let tutorialHostTime = CMTimeAdd(hostTime, delay)

        recordingStartSeconds = hostTime.seconds
        tutorial.startPlayback(atHostTime: tutorialHostTime)
        // Beeps at 3, 2, 1 (and the "go" ding when the tutorial starts),
        // scheduled on the audio clock relative to the camera's start time.
        if Self.countdownSoundEnabled {
            let hostNow = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            // The beeps are scheduled for when the iPhone SENDS the sound;
            // Bluetooth headphones / speakers play it a bit later. Start them
            // that much earlier, so you HEAR each beep as its number appears.
            let latency = min(max(AVAudioSession.sharedInstance().outputLatency, 0), 0.5)
            sounds.schedule(startingAt: hostTime.seconds + Self.readySeconds - hostNow - latency,
                            interval: 1)
        }
        phase = .countdown
        runCountdown(until: tutorialHostTime.seconds)
    }

    /// Shows 3 · 2 · 1 · GO, driven by the same clock the tutorial uses.
    private func runCountdown(until targetSeconds: Double) {
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            var lastShown = 0
            while true {
                guard let self, !Task.isCancelled else { return }
                let remaining = targetSeconds - CMClockGetTime(CMClockGetHostTimeClock()).seconds
                if remaining <= 0 { break }
                // 0 = "GET READY" (before the 3), then 3, 2, 1 – each number
                // appears exactly when its beep plays.
                let number = remaining > 3 ? 0 : Int(remaining.rounded(.up))
                if number != lastShown {
                    lastShown = number
                    withAnimation(.spring(duration: 0.4)) {
                        self.countdownValue = number
                    }
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
            guard let self, !Task.isCancelled else { return }
            withAnimation(.spring(duration: 0.3)) {
                self.countdownValue = nil
                self.showGo = true
            }
            if self.phase == .countdown {
                self.phase = .recording
            }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                self.showGo = false
            }
        }
    }

    private func stopRecordingTapped() {
        guard canStop else { return }
        beginFinishing()
        recorder.stopRecording()
    }

    /// The tutorial reached `endTime` (or its end): stop by itself.
    private func tutorialReachedEnd() {
        guard phase == .recording else { return }
        stopRecordingTapped()
    }

    /// Common part of every way a recording ends: stop the 3-2-1, pause the
    /// tutorial and remember where it stopped.
    private func beginFinishing() {
        countdownTask?.cancel()
        countdownTask = nil
        sounds.cancel()
        countdownValue = nil
        showGo = false
        // Stopped before the tutorial even started: nothing worth keeping.
        if phase != .recording {
            discardOnFinish = true
        }
        tutorial.hold()
        tutorialEndSeconds = tutorial.currentSeconds()
        phase = .finishing
    }

    // MARK: Finished

    private func recordingFinished(_ result: Result<URL, Error>, fileName: String) {
        // The recording ended on its own (e.g. a phone call or the app went
        // to the background): wrap up as if Stop was tapped.
        if isRecordingActive {
            beginFinishing()
        }

        switch result {
        case .success:
            guard !discardOnFinish, let project, let context else {
                VideoStorage.deleteVideo(named: fileName)
                backToIdle()
                return
            }
            let take = TakeStore.addTake(
                fileName: fileName,
                tutorialStart: startTime,
                tutorialEnd: max(tutorialEndSeconds, startTime),
                takeOffset: Self.countdownSeconds,
                recordRate: rate,
                to: project,
                context: context
            )
            if memoryTest {
                take.memoryTest = true
                try? context.save()
            }
            savedTake = take
            phase = .saved
            // Reviewing: the camera is not needed (saves battery). The
            // tutorial player stays loaded for "Record again".
            recorder.stop()

        case .failure(let error):
            VideoStorage.deleteVideo(named: fileName)
            if !discardOnFinish {
                errorMessage = "The recording could not be saved. \(error.localizedDescription)"
            }
            backToIdle()
        }
    }

    private func backToIdle() {
        phase = .idle
        guard !isEnded else { return }
        tutorial.moveToStart()
    }

    /// "Record again" (from the review): the saved take stays; restart the
    /// camera and go back to the start, ready for a new take.
    func recordAgain() {
        guard phase == .saved, !isEnded else { return }
        savedTake = nil
        phase = .idle
        tutorial.moveToStart()
        Task { await recorder.start() }
    }

    /// Close was confirmed in the "discard?" dialog.
    func discardAndClose() {
        switch phase {
        case .starting, .countdown, .recording:
            discardOnFinish = true
            beginFinishing()
            recorder.stopRecording()
        case .finishing:
            discardOnFinish = true
        case .saved:
            // The take was just saved: remove it again.
            if let take = savedTake, let context {
                TakeStore.delete(take, context: context)
                savedTake = nil
            }
        case .idle:
            break
        }
        finish(with: nil)
    }
}

// MARK: - The tutorial player

/// Plays the tutorial video during recording. Its own `AVPlayer`, separate
/// from the normal playback screen.
///
/// To start the tutorial at an exact moment relative to the camera we use
/// `setRate(_:time:atHostTime:)`. It only works when
/// `automaticallyWaitsToMinimizeStalling` is off (otherwise it crashes).
@MainActor
@Observable
private final class RecordTutorialPlayer {
    let player = AVPlayer()

    /// True when the first frame is shown and the player can start.
    private(set) var isReady = false
    private(set) var loadError: String? = nil

    /// Called when playback reaches the end time (or the end of the video).
    @ObservationIgnored var onReachedEnd: (@MainActor () -> Void)?

    @ObservationIgnored private var startSeconds: Double = 0
    @ObservationIgnored private var endSeconds: Double? = nil
    @ObservationIgnored private var rate: Float = 1
    @ObservationIgnored private var statusObservation: NSKeyValueObservation? = nil
    @ObservationIgnored private var timeObserver: Any? = nil
    @ObservationIgnored private var endObserver: NSObjectProtocol? = nil
    /// True while the tutorial must NOT be playing.
    @ObservationIgnored private var isHeld = true
    /// True once playback was scheduled: only then does the end time count.
    @ObservationIgnored private var watchingEnd = false
    /// Bumped on every seek so old seek callbacks are ignored.
    @ObservationIgnored private var seekGeneration = 0

    private static let timeScale: CMTimeScale = 60_000

    init() {
        // REQUIRED before using setRate(_:time:atHostTime:).
        player.automaticallyWaitsToMinimizeStalling = false
        // At the end of the video just stop.
        player.actionAtItemEnd = .pause
    }

    func configure(startTime: Double, endTime: Double?, rate: Float) {
        startSeconds = max(startTime, 0)
        if let endTime, endTime > startSeconds {
            endSeconds = endTime
        } else {
            endSeconds = nil
        }
        self.rate = rate
    }

    /// Loads the video and shows its first frame at the start time.
    func prepare(url: URL?) {
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            loadError = "The tutorial video could not be found."
            return
        }
        loadError = nil
        isReady = false
        removeObservers()

        let item = AVPlayerItem(url: url)
        // Keeps the music's pitch normal when playing slower.
        item.audioTimePitchAlgorithm = .spectral
        player.automaticallyWaitsToMinimizeStalling = false
        player.replaceCurrentItem(with: item)
        installObservers(for: item)
    }

    /// Back to the start time, paused, so the first frame shows again.
    func moveToStart() {
        guard let item = player.currentItem, item.status == .readyToPlay else { return }
        isReady = false
        isHeld = true
        watchingEnd = false
        player.pause()

        seekGeneration += 1
        let generation = seekGeneration
        let target = CMTime(seconds: startSeconds, preferredTimescale: Self.timeScale)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            // AVFoundation may call this on any thread: hop to the main actor.
            guard let self else { return }
            Task { @MainActor in
                self.seekFinished(finished, generation: generation)
            }
        }
    }

    /// Starts playing at `hostTime` (iPhone host clock), from the start time.
    func startPlayback(atHostTime hostTime: CMTime) {
        isHeld = false
        watchingEnd = true
        player.automaticallyWaitsToMinimizeStalling = false
        if player.currentItem?.status == .readyToPlay {
            player.setRate(rate,
                           time: CMTime(seconds: startSeconds, preferredTimescale: Self.timeScale),
                           atHostTime: hostTime)
        } else {
            // Should not happen (Record is disabled until ready), but never crash.
            player.rate = rate
        }
    }

    /// Pauses and keeps it paused (even if a scheduled start was pending).
    func hold() {
        isHeld = true
        watchingEnd = false
        player.pause()
    }

    func currentSeconds() -> Double {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(seconds, 0) : startSeconds
    }

    func tearDown() {
        isHeld = true
        watchingEnd = false
        player.pause()
        removeObservers()
    }

    // MARK: Private

    private func installObservers(for item: AVPlayerItem) {
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription
            guard let self else { return }
            Task { @MainActor in
                self.itemStatusChanged(status, message: message)
            }
        }

        // ~30 checks per second: pauses at the end time, keeps a "held"
        // player from playing.
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30),
                                                      queue: .main) { [weak self] time in
            guard let self else { return }
            // We asked for the main queue, so we are on the main actor.
            MainActor.assumeIsolated {
                self.tick(time.seconds)
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.reachedItemEnd()
            }
        }
    }

    private func removeObservers() {
        statusObservation?.invalidate()
        statusObservation = nil
        if let token = timeObserver {
            player.removeTimeObserver(token)
        }
        timeObserver = nil
        if let token = endObserver {
            NotificationCenter.default.removeObserver(token)
        }
        endObserver = nil
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, message: String?) {
        switch status {
        case .readyToPlay:
            if !isReady { moveToStart() }
        case .failed:
            loadError = message ?? "The tutorial video could not be opened."
        default:
            break
        }
    }

    private func seekFinished(_ finished: Bool, generation: Int) {
        guard finished, generation == seekGeneration else { return }
        isReady = true
        // Get the audio/video pipeline warm so the scheduled start is on time.
        if player.status == .readyToPlay, player.currentItem?.status == .readyToPlay {
            player.preroll(atRate: rate) { _ in }
        }
    }

    private func tick(_ seconds: Double) {
        if isHeld {
            if player.rate != 0 { player.pause() }
            return
        }
        guard watchingEnd, let end = endSeconds, seconds.isFinite, seconds >= end else { return }
        watchingEnd = false
        onReachedEnd?()
    }

    private func reachedItemEnd() {
        guard watchingEnd else { return }
        watchingEnd = false
        onReachedEnd?()
    }
}

// MARK: - Tutorial picture

/// Bridges a UIKit view that hosts an `AVPlayerLayer` into SwiftUI.
/// The background is clear so the tutorial can be a see-through "ghost".
@MainActor
private struct RecordTutorialLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> RecordTutorialUIView {
        let view = RecordTutorialUIView()
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: RecordTutorialUIView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

/// A UIView whose own layer *is* an AVPlayerLayer.
private final class RecordTutorialUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // Safe: `layerClass` above guarantees the layer type.
        layer as! AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}
