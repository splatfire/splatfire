import SwiftUI
import SwiftData

/// The practice screen for one project:
/// video on top, playback controls below, the scrollable 8-count list under that.
@MainActor
struct ProjectDetailView: View {
    @Bindable var project: Project
    @Environment(\.modelContext) private var modelContext

    @State private var controller = PlayerController()

    // Updated by `PlayheadTracker` only when they actually change, so this big
    // view doesn't redraw 60 times a second while the video plays.
    @State private var currentIndex: Int?
    @State private var countLabel: String?

    @State private var editing: EditTarget?
    @State private var showTempo = false
    @State private var followPlayback = true
    @State private var showReplaceConfirm = false
    @State private var showReplaceSheet = false
    @State private var isGrabbing = false
    @State private var snapshotCount = 0
    @State private var flash = false
    @State private var alertMessage: String?

    // Recording yourself and comparing (see Recording/ and Compare/).
    @State private var showRecord = false
    @State private var showTakes = false
    @State private var comparing: CompareTarget?
    /// Actions to run once a sheet/cover has finished closing (SwiftUI can't
    /// open a new full-screen cover while another one is still closing).
    @State private var pendingCompare: Take?
    @State private var pendingRecord = false
    /// Which video file the player has loaded, so coming back from the
    /// record/compare screens doesn't reload it (and lose your place).
    @State private var loadedFileName: String?
    /// Identifies this screen to the Apple Watch remote.
    @State private var watchID = UUID()
    /// False while another screen covers this one (or after going back).
    @State private var isOnScreen = false
    /// For the practice streak: how long the video has played this visit.
    @State private var playStartedAt: Date?
    @State private var playedSeconds: Double = 0
    /// Big video: the video takes most of the screen and the 8-count list
    /// gets smaller. Remembered between launches.
    @AppStorage("bigVideo") private var bigVideo = false

    // Practice tools (see Practice/).
    @State private var coach = PracticeCoach()
    @State private var cues = CountCues()
    @State private var zoom = VideoZoom()
    @State private var showTools = false
    @State private var newSection: SectionDraft?
    @State private var formationTarget: EditTarget?
    @AppStorage("showFormation") private var showFormation = true
    /// Memory test: the video is covered (not remembered: it's a test, not a setting).
    @State private var memoryTest = false
    @State private var peeking = false
    @AppStorage("showNextMove") private var showNextMove = true
    @AppStorage("cueCountIn") private var cueCountIn = false
    @AppStorage("cueCountInLoop") private var cueCountInLoop = false
    @AppStorage("cueClick") private var cueClick = false
    @AppStorage("cueSayCounts") private var cueSayCounts = false
    @AppStorage("cueSayMoves") private var cueSayMoves = false
    @AppStorage("cueFade") private var cueFade = false

    /// The 8-count layout for the current BPM / offset / video length.
    private var grid: CountGrid {
        CountGrid(bpm: project.bpm, offset: project.offset, duration: controller.duration)
    }

    /// True when the project has a video and the file is really there.
    private var hasVideo: Bool {
        guard let url = project.videoURL else { return false }
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    var body: some View {
        Group {
            if hasVideo {
                practiceView
            } else {
                noVideoView
            }
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        // (Re)load the video whenever the project's video file changes.
        .task(id: project.videoFileName) {
            guard hasVideo, let url = project.videoURL,
                  loadedFileName != project.videoFileName else { return }
            loadedFileName = project.videoFileName
            await controller.load(url: url)
        }
        .onAppear {
            WatchRemoteHandlers.attachPractice(id: watchID, project: project, controller: controller)
            cues.start(controller: controller)
            updateCues()
            // The practice screen can turn sideways too. A record/compare
            // screen closing locks to portrait when it goes; unlock again
            // just after that.
            isOnScreen = true
            OrientationLock.allowLandscape()
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                if isOnScreen { OrientationLock.allowLandscape() }
            }
        }
        .onChange(of: controller.isPlaying) { _, playing in
            countPlayTime(playing: playing)
        }
        // Recording a take counts as practice too.
        .onChange(of: project.takes.count) { old, new in
            if new > old { PracticeLog.shared.recordPractice(of: project) }
        }
        .onDisappear {
            countPlayTime(playing: false)
            isOnScreen = false
            OrientationLock.portraitOnly()
            WatchRemote.shared.detach(id: watchID)
            cues.stop()
            controller.tearDown()
        }
        .onChange(of: cueSettings) { _, _ in updateCues() }
        .onChange(of: grid) { _, _ in
            updateCues()
            rememberEightCountTotal()
        }
        // The coach moves on after enough runs of the loop…
        .onChange(of: controller.loopWraps) { _, _ in
            coach.loopWrapped(controller: controller, grid: grid)
        }
        // …and stops when you switch the loop off or jump out of it.
        .onChange(of: controller.isLooping) { _, looping in
            if !looping { coach.stop() }
        }
        .sheet(isPresented: $showTools) {
            PracticeToolsSheet(
                project: project,
                grid: grid,
                currentIndex: currentIndex,
                memoryTest: $memoryTest,
                showNextMove: $showNextMove,
                showFormation: $showFormation,
                cues: cueSettingsBinding,
                onBuildUp: { first, last, runs, name in
                    coach.startBuildUp(first: first, last: last, runs: runs, rate: controller.rate,
                                       name: name, controller: controller, grid: grid)
                },
                onSpeedLadder: { first, last, runs, name in
                    coach.startSpeedLadder(first: first, last: last, runs: runs, name: name,
                                           controller: controller, grid: grid)
                },
                onLoopSection: { loopSection($0) },
                voiceStatus: cues.voiceStatus
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $formationTarget) { target in
            FormationEditorSheet(project: project, countIndex: target.id, count: grid.numberOfEightCounts)
        }
        .sheet(item: $newSection) { draft in
            SectionEditorSheet(draft: draft, count: grid.numberOfEightCounts) { saved in
                saved.save(to: project, context: modelContext)
            }
        }
        .sheet(item: $editing) { target in
            NoteEditorSheet(project: project, countIndex: target.id, grid: grid)
        }
        .sheet(isPresented: $showTempo) { tempoSheet }
        .sheet(isPresented: $showReplaceSheet) { replaceVideoSheet }
        .sheet(isPresented: $showTakes, onDismiss: runPendingActions) {
            TakesListView(
                project: project,
                tutorialMirrored: controller.isMirrored,
                onOpen: { take in
                    pendingCompare = take
                    showTakes = false
                },
                onRecordNew: {
                    pendingRecord = true
                    showTakes = false
                }
            )
        }
        .fullScreenCover(isPresented: $showRecord, onDismiss: runPendingActions) {
            recordView
        }
        .fullScreenCover(item: $comparing) { target in
            CompareView(project: project, take: target.take, tutorialMirrored: controller.isMirrored)
        }
        .confirmationDialog(
            "Replace the video?",
            isPresented: $showReplaceConfirm,
            titleVisibility: .visible
        ) {
            Button("Choose New Video", role: .destructive) { showReplaceSheet = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app's copy of the current video will be deleted. Your notes and snapshots stay.")
        }
        .alert("Heads up", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
        .sensoryFeedback(.success, trigger: snapshotCount)
    }

    // MARK: - Main layout

    private var practiceView: some View {
        GeometryReader { geo in
            if geo.size.width > geo.size.height {
                // Sideways: video and controls on the left, the 8-counts on the right.
                let leftWidth = (geo.size.width * 0.6).rounded()
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        videoCard(available: CGSize(width: leftWidth - 24, height: max(geo.size.height - 190, 120)),
                                  fitWidth: true)
                        coachBarIfNeeded
                        Spacer(minLength: 0)
                        playbackControls
                    }
                    .frame(width: leftWidth)
                    Divider().overlay(Theme.hairline)
                    countList
                }
                .animation(.snappy, value: coach.isActive)
            } else {
                VStack(spacing: 0) {
                    // Video: a rounded card with 16 pt side padding, never taller
                    // than ~1/3 of the screen (2/3 with "bigger video"), so the
                    // controls and the 8-count list still fit.
                    videoCard(available: CGSize(width: max(geo.size.width - 32, 0),
                                                height: geo.size.height * (bigVideo ? 0.62 : 0.34)),
                              fitWidth: false)
                    coachBarIfNeeded
                    playbackControls
                    Divider().overlay(Theme.hairline)
                    countList
                }
                .animation(.snappy, value: coach.isActive)
            }
        }
    }

    /// The video with everything on it (tools, zoom, hints, memory test).
    /// `fitWidth`: shrink the card to the video's shape (landscape layout).
    private func videoCard(available: CGSize, fitWidth: Bool) -> some View {
        let aspect = max(controller.videoAspectRatio, 0.1)
        let videoHeight = min(available.width / aspect, available.height)
        let videoWidth = fitWidth ? min(available.width, videoHeight * aspect) : available.width
        let videoSize = CGSize(width: videoWidth, height: videoHeight)
        return VideoSurface(controller: controller, zoom: zoom.scale, pan: zoom.offset)
            .frame(width: videoWidth, height: videoHeight)
            .overlay {
                // Short white flash = "snapshot taken".
                Color.white.opacity(flash ? 0.6 : 0)
                    .allowsHitTesting(false)
            }
            .overlay {
                if memoryTest {
                    MemoryTestCover(controller: controller, grid: grid, isPeeking: $peeking)
                        .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
            // For the UI test (pinch zoom).
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("practiceVideo")
            // Double-tap the video, or tap the corner button, to make it bigger/smaller.
            .onTapGesture(count: 2) { toggleBigVideo() }
            // Pinch to zoom in on the feet / hands; drag to look around.
            .gesture(
                MagnifyGesture()
                    .onChanged { zoom.pinch($0.magnification, in: videoSize) }
                    .onEnded { _ in withAnimation(.snappy) { zoom.settle(in: videoSize) } }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { zoom.drag($0.translation, in: videoSize) }
                    .onEnded { _ in zoom.settle(in: videoSize) },
                including: zoom.isZoomed ? .all : .subviews
            )
            .overlay(alignment: .bottomTrailing) {
                Button { toggleBigVideo() } label: {
                    Image(systemName: bigVideo ? "arrow.down.right.and.arrow.up.left"
                                               : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(width: 36, height: 36)
                        .glassSurface(Circle(), fallback: Color.black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .padding(8)
                .accessibilityLabel(bigVideo ? "Smaller video" : "Bigger video")
            }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 8) {
                    Button { showTools = true } label: {
                        Image(systemName: "figure.dance")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(coach.isActive || memoryTest ? Theme.accent : Color.white)
                            .frame(width: 36, height: 36)
                            .glassSurface(Circle(), fallback: Color.black.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Practice tools")
                    // AirPlay to a TV (the phone stays the remote).
                    AirPlayButton()
                        .frame(width: 22, height: 22)
                        .frame(width: 36, height: 36)
                        .glassSurface(Circle(), fallback: Color.black.opacity(0.55))
                }
                .padding(8)
            }
            .overlay(alignment: .top) {
                if zoom.isZoomed {
                    Button {
                        withAnimation(.snappy) { zoom.reset() }
                    } label: {
                        Label(String(format: "%.1f×", zoom.scale), systemImage: "xmark")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .glassSurface(Capsule(), fallback: Color.black.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 11)
                    .accessibilityLabel("Zoomed in. Show the whole video")
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let hint = nextMove {
                    NextMoveHint(index: hint.index, text: hint.text)
                        .padding(.leading, 8)
                        .padding(.trailing, 52)
                        .padding(.bottom, 8)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let shown = currentFormation {
                    FormationMiniMap(formation: shown)
                        .frame(width: 84, height: 52)
                        .accessibilityIdentifier("videoFormation")
                        .padding(.top, controller.isMirrored ? 36 : 8)
                        .padding(.trailing, 8)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.snappy, value: nextMove?.index)
            .animation(.easeInOut(duration: 0.2), value: memoryTest)
            .padding(.top, 6)
            .background(
                PlayheadTracker(
                    controller: controller,
                    grid: grid,
                    currentIndex: $currentIndex,
                    countLabel: $countLabel
                )
            )
    }

    @ViewBuilder
    private var coachBarIfNeeded: some View {
        if coach.isActive || fadingCueLevel != nil {
            CoachBar(
                coach: coach,
                cueLevel: fadingCueLevel,
                onNext: { coach.next(controller: controller, grid: grid) },
                onRestart: { coach.restart(controller: controller, grid: grid) },
                onStop: { coach.stop() }
            )
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var playbackControls: some View {
        PlaybackControlsView(
            controller: controller,
            countLabel: countLabel,
            onSnapshot: { takeSnapshot() }
        )
        .padding(.vertical, Theme.spacingM)
    }

    private var countList: some View {
        CountListView(
            project: project,
            grid: grid,
            currentIndex: currentIndex,
            loopedRange: loopedRange,
            sections: project.sortedSections,
            loopedSectionID: loopedSectionID,
            followPlayback: followPlayback && controller.isPlaying,
            onJump: { jump(to: $0) },
            onToggleLoop: { toggleLoop($0) },
            onEdit: { editing = EditTarget(id: $0) },
            onSetupTempo: { showTempo = true },
            onLoopSection: { loopSection($0) },
            onNewSection: { index in
                newSection = SectionDraft(start: index,
                                          end: min(index + 3, max(grid.numberOfEightCounts - 1, 0)))
            },
            onSetMastery: { index, mastery in
                NoteStore.setMastery(mastery, for: index, in: project, context: modelContext)
            },
            onFormation: { formationTarget = EditTarget(id: $0) }
        )
    }

    // MARK: - Practice tools

    /// The next 8-count's note, for the hint on the video. Hidden in the
    /// memory test (unless you're peeking) – that would be cheating.
    private var nextMove: (index: Int, text: String)? {
        guard showNextMove, grid.isValid, !memoryTest || peeking else { return nil }
        let next = (currentIndex ?? -1) + 1
        guard next < grid.numberOfEightCounts,
              let text = NextMoveHint.text(of: project.note(for: next)) else { return nil }
        return (next, text)
    }

    /// Where everyone stands in the 8-count that's playing (or the last one
    /// before it that has a formation). Hidden in the memory test.
    private var currentFormation: Formation? {
        guard showFormation, !memoryTest, grid.isValid else { return nil }
        return Formation.effective(for: currentIndex ?? 0, in: project)?.formation
    }

    /// The 8-counts the loop covers, when it lines up with whole 8-counts.
    private var loopedRange: ClosedRange<Int>? {
        guard controller.isLooping else { return nil }
        if let index = controller.loopedEightCount { return index...index }
        guard grid.isValid, let a = controller.loopStart, let b = controller.loopEnd,
              let first = grid.index(at: a), let last = grid.index(at: max(b - 0.01, a)),
              abs(max(grid.start(of: first), 0) - a) < 0.02,
              abs(grid.end(of: last) - b) < 0.02 else { return nil }
        return first...last
    }

    private var loopedSectionID: UUID? {
        guard let range = loopedRange else { return nil }
        return project.sections.first { section in
            let last = min(section.endIndex, grid.numberOfEightCounts - 1)
            return section.startIndex == range.lowerBound && last == range.upperBound
        }?.id
    }

    /// The cue volume while "Fade as I repeat" is turning it down.
    private var fadingCueLevel: Float? {
        guard cueFade, cueSettings.duringPlayback, controller.isLooping, cues.level < 0.999 else { return nil }
        return cues.level
    }

    private var cueSettings: CountCues.Settings {
        CountCues.Settings(countIn: cueCountIn, countInEveryLoop: cueCountInLoop, click: cueClick,
                           sayCounts: cueSayCounts, sayMoves: cueSayMoves, fade: cueFade)
    }

    private var cueSettingsBinding: Binding<CountCues.Settings> {
        Binding(
            get: { cueSettings },
            set: { new in
                cueCountIn = new.countIn
                cueCountInLoop = new.countInEveryLoop
                cueClick = new.click
                cueSayCounts = new.sayCounts
                cueSayMoves = new.sayMoves
                cueFade = new.fade
            }
        )
    }

    private func updateCues() {
        controller.countInOnLoop = cueCountIn && cueCountInLoop
        cues.update(settings: cueSettings, grid: grid) { [project] index in
            NextMoveHint.text(of: project.note(for: index))
        }
    }

    /// Adds up playing time; after a minute today counts as a practice day.
    private func countPlayTime(playing: Bool) {
        if playing {
            if playStartedAt == nil { playStartedAt = .now }
            return
        }
        guard let started = playStartedAt else { return }
        playStartedAt = nil
        let before = playedSeconds
        playedSeconds += Date.now.timeIntervalSince(started)
        if before < 60 && playedSeconds >= 60 {
            PracticeLog.shared.recordPractice(of: project)
        }
    }

    /// Stores how many 8-counts there are, for the progress bar in the project list.
    private func rememberEightCountTotal() {
        let total = grid.isValid ? grid.numberOfEightCounts : 0
        guard total > 0, project.eightCountTotal != total else { return }
        project.eightCountTotal = total
        try? modelContext.save()
    }

    /// Loops a whole section (or stops it if it's already looping).
    private func loopSection(_ section: PracticeSection) {
        guard grid.isValid, section.startIndex < grid.numberOfEightCounts else { return }
        coach.stop()
        if loopedSectionID == section.id {
            controller.clearLoop()
            return
        }
        let last = min(section.endIndex, grid.numberOfEightCounts - 1)
        controller.loopSpan(start: max(grid.start(of: section.startIndex), 0), end: grid.end(of: last))
        if !controller.isPlaying { controller.play() }
    }

    /// Shown when the project has no video yet (e.g. right after importing
    /// someone's notes) or the video file has gone missing.
    private var noVideoView: some View {
        ScrollView {
            VStack(spacing: 20) {
                ContentUnavailableView {
                    Label("No video yet", systemImage: "video.badge.plus")
                } description: {
                    if let name = project.originalVideoName {
                        Text("Add the video for this project. It was originally \"\(name)\".")
                    } else {
                        Text("Add the tutorial or dance practice video for this project.")
                    }
                }
                // The import buttons live in a sheet: SwiftUI can get confused
                // by two `.fileImporter`s in one screen hierarchy (the project
                // list already has one for importing notes).
                Button {
                    showReplaceSheet = true
                } label: {
                    Label("Add Video", systemImage: "plus")
                }
                .buttonStyle(.big(isOn: true))
                .padding(.horizontal, 24)
            }
            .padding(.top, 40)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text(project.title).font(.headline)
                if !project.section.isEmpty {
                    Text(project.section)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                startRecording()
            } label: {
                Label("Record Yourself", systemImage: "record.circle")
            }
            .disabled(!hasVideo)
        }
        ToolbarItem(placement: .topBarTrailing) {
            ExportProjectButton(project: project)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    showTempo = true
                } label: {
                    Label("Tempo & Count 1…", systemImage: "metronome")
                }
                Button {
                    showTakes = true
                } label: {
                    Label("My Takes (\(project.takes.count))", systemImage: "person.2.crop.square.stack")
                }
                Toggle(isOn: $followPlayback) {
                    Label("Follow Playback in List", systemImage: "list.bullet.below.rectangle")
                }
                if hasVideo {
                    Button(role: .destructive) {
                        showReplaceConfirm = true
                    } label: {
                        Label("Replace Video…", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: - Sheets

    private var tempoSheet: some View {
        TempoSetupSheet(
            project: project,
            currentTime: { controller.currentTime },
            playbackRate: Double(controller.rate),
            onSeek: { controller.seek(to: $0) }
        )
        // A play/pause bar inside the sheet, so you can tap along to the
        // music without closing it.
        .safeAreaInset(edge: .bottom) {
            SheetPlayBar(controller: controller)
        }
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }

    private var replaceVideoSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text(hasVideo
                     ? "Pick the new video. Notes stay attached to their 8-count numbers."
                     : "Pick the video for this project.")
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                VideoImportButtons { stored, original in
                    attachVideo(stored: stored, original: original)
                    showReplaceSheet = false
                }
                Spacer()
            }
            .padding(24)
            .navigationTitle(hasVideo ? "Replace Video" : "Add Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showReplaceSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Record & compare

    /// The record screen. It starts where you are in the video, at your
    /// current speed and mirror setting. If an A-B loop (or a looped
    /// 8-count) is on, it records exactly that part.
    private var recordView: some View {
        let looping = controller.isLooping
        let start = looping ? (controller.loopStart ?? controller.currentTime) : controller.currentTime
        let end = looping ? controller.loopEnd : nil
        return RecordView(
            project: project,
            startTime: start,
            endTime: end,
            rate: Double(controller.rate),
            tutorialMirrored: controller.isMirrored,
            startHidden: memoryTest,
            onFinished: { take in
                pendingCompare = take   // opened after the cover has closed
                showRecord = false
            }
        )
    }

    private func startRecording() {
        controller.pause()
        showRecord = true
    }

    /// Runs what was requested from inside a sheet/cover once it is gone.
    private func runPendingActions() {
        if let take = pendingCompare {
            pendingCompare = nil
            comparing = CompareTarget(take: take)
        } else if pendingRecord {
            pendingRecord = false
            startRecording()
        }
    }

    // MARK: - Actions

    private func toggleBigVideo() {
        withAnimation(.snappy) { bigVideo.toggle() }
    }

    /// Tap on an 8-count: jump to its first beat.
    private func jump(to index: Int) {
        guard grid.isValid else { return }
        controller.seek(to: max(grid.start(of: index), 0))
    }

    /// Loop just this 8-count, or stop looping it if it already loops.
    private func toggleLoop(_ index: Int) {
        guard grid.isValid else { return }
        coach.stop()
        if controller.isLooping && controller.loopedEightCount == index {
            controller.clearLoop()
        } else {
            controller.loopEightCount(index, start: max(grid.start(of: index), 0), end: grid.end(of: index))
            if !controller.isPlaying { controller.play() }
        }
    }

    /// Grabs the current frame and attaches it to the 8-count at the playhead.
    private func takeSnapshot() {
        guard let url = project.videoURL, !isGrabbing else { return }
        guard grid.isValid else {
            alertMessage = "Set the BPM first (tap the tempo bar above the list), so the snapshot can be attached to an 8-count."
            return
        }
        let time = controller.currentTime
        // Before count 1 (the intro) counts as the first 8-count.
        let index = grid.index(at: time) ?? 0
        let mirrored = controller.isMirrored
        isGrabbing = true
        Task {
            defer { isGrabbing = false }
            do {
                let data = try await FrameGrabber.jpegData(from: url, at: time, mirrored: mirrored)
                NoteStore.addSnapshot(jpegData: data, time: time, countIndex: index,
                                      to: project, context: modelContext)
                snapshotCount += 1
                withAnimation(.easeOut(duration: 0.05)) { flash = true }
                // Wait a moment before fading out; setting it back in the same
                // instant would cancel the flash before it's ever drawn.
                try? await Task.sleep(for: .milliseconds(80))
                withAnimation(.easeIn(duration: 0.35)) { flash = false }
            } catch {
                alertMessage = "Couldn't grab this frame: \(error.localizedDescription)"
            }
        }
    }

    /// Stores a newly imported video on the project (replacing any old one).
    private func attachVideo(stored: String, original: String) {
        controller.pause()
        let oldName = project.videoFileName
        project.videoFileName = stored
        project.originalVideoName = original
        project.updatedAt = .now
        try? modelContext.save()
        if oldName != stored { VideoStorage.deleteVideo(named: oldName) }
    }
}

/// Wraps a take so `.fullScreenCover(item:)` has something `Identifiable`
/// without relying on how SwiftData models conform to `Identifiable`.
private struct CompareTarget: Identifiable {
    let take: Take
    var id: PersistentIdentifier { take.persistentModelID }
}

/// Identifies which 8-count the note editor is open for.
private struct EditTarget: Identifiable {
    let id: Int
}

/// Invisible helper view. It reads the playhead (which changes ~60×/s) and
/// only writes `currentIndex` / `countLabel` when they really change.
/// Keeping this in its own tiny view stops the whole screen from redrawing
/// on every frame.
private struct PlayheadTracker: View {
    let controller: PlayerController
    let grid: CountGrid
    @Binding var currentIndex: Int?
    @Binding var countLabel: String?

    var body: some View {
        let time = controller.currentTime
        let index = grid.index(at: time)
        let label = Self.label(grid: grid, time: time)
        Color.clear
            .onAppear { update(index, label) }
            .onChange(of: index) { _, newValue in update(newValue, label) }
            .onChange(of: label) { _, newValue in update(index, newValue) }
    }

    private func update(_ index: Int?, _ label: String?) {
        if currentIndex != index { currentIndex = index }
        if countLabel != label { countLabel = label }
    }

    /// "8-count 5 · 3", "Intro" before count 1, nil without BPM.
    static func label(grid: CountGrid, time: Double) -> String? {
        guard grid.isValid else { return nil }
        guard let index = grid.index(at: time), let beat = grid.beat(at: time) else { return "Intro" }
        return "8-count \(index + 1) · \(beat)"
    }
}

/// Small play/pause bar shown at the bottom of the tempo sheet.
private struct SheetPlayBar: View {
    let controller: PlayerController

    var body: some View {
        HStack(spacing: 12) {
            Text(formatTime(controller.currentTime))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .frame(minWidth: 90, alignment: .leading)
            Button {
                controller.togglePlayPause()
            } label: {
                Label(controller.isPlaying ? "Pause" : "Play",
                      systemImage: controller.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.big(isOn: true))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
