import AVFoundation
import CoreMedia
import Observation
import QuartzCore
import UIKit

/// Plays the tutorial and one of your takes at the same time, perfectly in sync.
///
/// Everything is measured in *tutorial time*. The tutorial player has the
/// music; the take player is muted. When playing starts, both players are
/// told "be at THIS time at THAT exact moment on the device clock"
/// (`setRate(_:time:atHostTime:)`), which keeps them locked together.
///
/// Views read the properties directly (thanks to `@Observable` SwiftUI redraws
/// by itself). Call `load()` once and `tearDown()` from `.onDisappear`.
@MainActor
@Observable
final class SyncedPlayback {
    // MARK: - State the UI reads

    /// Shows the tutorial video (has the sound).
    let tutorialPlayer: AVPlayer
    /// Shows your recording (muted).
    let takePlayer: AVPlayer

    /// True once both videos are loaded and ready to show.
    private(set) var isReady = false
    private(set) var isPlaying = false
    /// Playhead in tutorial seconds.
    private(set) var currentTime: Double = 0
    /// The part of the tutorial that your take covers.
    private(set) var range: ClosedRange<Double> = 0...1
    /// Length of the whole tutorial video (0 until loaded).
    private(set) var tutorialDuration: Double = 0
    /// Tutorial playback speed (the take speed is derived from it).
    private(set) var rate: Float = 1.0
    /// When on, the range repeats: at its end we jump back to its start.
    var isLooping = true
    /// Current fine-tune of the sync, in seconds of the take.
    private(set) var nudge: Double = 0
    /// A readable message if a video could not be opened.
    private(set) var loadError: String? = nil

    /// Speeds offered in the UI.
    nonisolated static let speeds: [Float] = [0.25, 0.5, 0.75, 1.0, 2.0]
    /// Frame stepping uses this fixed frame rate.
    nonisolated static let stepFPS: Double = 30

    /// "0.5×" / "1×" for a speed value.
    nonisolated static func speedLabel(_ speed: Double) -> String {
        String(format: "%g×", speed)
    }

    // MARK: - Private bookkeeping (not observed by SwiftUI)

    private let tutorialURL: URL?
    private let takeModel: Take

    @ObservationIgnored private var takeDuration: Double = 0
    @ObservationIgnored private var timeObserver: Any? = nil
    @ObservationIgnored private var endObserver: NSObjectProtocol? = nil
    @ObservationIgnored private var loadGeneration = 0

    // "Chase time" seeking (same idea as PlayerController): while one precise
    // seek runs we only remember the newest target and go there afterwards.
    @ObservationIgnored private var isSeekInProgress = false
    @ObservationIgnored private var chaseTime: Double = 0
    @ObservationIgnored private var chaseVersion = 0
    @ObservationIgnored private var pendingSeeks = 0
    /// Bumped to make old seek callbacks harmless.
    @ObservationIgnored private var seekGeneration = 0

    // Timing helpers for the tick handler (all in CACurrentMediaTime seconds).
    @ObservationIgnored private var settleUntil: CFTimeInterval = 0
    @ObservationIgnored private var lastDriftCheck: CFTimeInterval = 0
    @ObservationIgnored private var lastResync: CFTimeInterval = 0

    /// 60 000 ticks per second, so 1/30 s and 1/60 s are exact.
    private static let timeScale: CMTimeScale = 60_000

    // MARK: - Setup

    init(project: Project, take: Take) {
        self.tutorialURL = project.videoURL
        self.takeModel = take

        let tutorial = AVPlayer()
        let takePlayer = AVPlayer()
        // REQUIRED: setRate(_:time:atHostTime:) raises an exception otherwise.
        tutorial.automaticallyWaitsToMinimizeStalling = false
        takePlayer.automaticallyWaitsToMinimizeStalling = false
        // At the end of a video just stop (we handle looping ourselves).
        tutorial.actionAtItemEnd = .pause
        takePlayer.actionAtItemEnd = .pause
        // The recording has no sound; muted anyway so only the tutorial is heard.
        takePlayer.isMuted = true
        self.tutorialPlayer = tutorial
        self.takePlayer = takePlayer
        self.nudge = take.syncNudge
        // Start at the speed you recorded at (your video then plays as filmed,
        // the tutorial as you heard it). 1× = both at the song's real tempo.
        let recorded = Float(take.timing.rate)
        self.rate = Self.speeds.min { abs($0 - recorded) < abs($1 - recorded) } ?? 1
    }

    /// Plays sound even when the silent switch is on (and after recording,
    /// when the session was set up for the camera).
    static func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)
    }

    /// Opens both videos and parks them at the start of the range.
    /// Safe to call again (e.g. when the view reappears).
    func load() async {
        if isReady {
            installObserversIfNeeded()
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        loadError = nil

        guard let tutorialURL else {
            loadError = "This project has no tutorial video."
            return
        }
        let takeURL = takeModel.videoURL
        guard FileManager.default.fileExists(atPath: takeURL.path) else {
            loadError = "The recording file is missing."
            return
        }

        let tutorialAsset = AVURLAsset(url: tutorialURL)
        let takeAsset = AVURLAsset(url: takeURL)
        do {
            let tutorialLength = try await tutorialAsset.load(.duration)
            let takeLength = try await takeAsset.load(.duration)
            guard generation == loadGeneration else { return }

            let tutorialSeconds = tutorialLength.seconds
            tutorialDuration = tutorialSeconds.isFinite ? max(tutorialSeconds, 0) : 0
            let takeSeconds = takeLength.seconds
            takeDuration = takeSeconds.isFinite ? max(takeSeconds, 0) : 0

            // The range your take covers, kept inside the tutorial.
            let full = takeModel.timing.tutorialRange
            var lower = max(full.lowerBound, 0)
            var upper = full.upperBound
            if tutorialDuration > 0 {
                lower = min(lower, tutorialDuration)
                upper = min(upper, tutorialDuration)
            }
            upper = max(upper, lower)
            range = lower...upper

            let tutorialItem = AVPlayerItem(asset: tutorialAsset)
            // Keeps the music's pitch normal when playing slower.
            tutorialItem.audioTimePitchAlgorithm = .spectral
            let takeItem = AVPlayerItem(asset: takeAsset)
            takeItem.audioTimePitchAlgorithm = .spectral

            seekGeneration += 1
            isSeekInProgress = false
            removeObservers()
            tutorialPlayer.replaceCurrentItem(with: tutorialItem)
            takePlayer.replaceCurrentItem(with: takeItem)

            // setRate(_:time:atHostTime:) needs items that are ready to play.
            let tutorialOK = await waitUntilReady(tutorialItem)
            let takeOK = await waitUntilReady(takeItem)
            guard !Task.isCancelled, generation == loadGeneration else { return }
            guard tutorialOK else {
                loadError = tutorialItem.error?.localizedDescription ?? "The tutorial video could not be opened."
                return
            }
            guard takeOK else {
                loadError = takeItem.error?.localizedDescription ?? "Your recording could not be opened."
                return
            }

            installObserversIfNeeded()
            currentTime = range.lowerBound
            seekPrecisely(to: range.lowerBound)
            isReady = true
        } catch {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            loadError = error.localizedDescription
        }
    }

    /// Waits (max ~10 s) until an item is ready to play. False if it failed.
    private func waitUntilReady(_ item: AVPlayerItem) async -> Bool {
        var waited = 0.0
        while item.status == .unknown {
            if Task.isCancelled || waited > 10 { return false }
            try? await Task.sleep(nanoseconds: 30_000_000)
            waited += 0.03
        }
        return item.status == .readyToPlay
    }

    /// Removes observers, pauses and lets the screen sleep again.
    /// Call from `.onDisappear`.
    func tearDown() {
        loadGeneration += 1
        seekGeneration += 1
        isSeekInProgress = false
        removeObservers()
        tutorialPlayer.pause()
        takePlayer.pause()
        setPlaying(false)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Play / pause

    /// Starts both videos at the playhead (or at the range start when the
    /// playhead is at the end).
    func play() {
        guard isReady else { return }
        installObserversIfNeeded()
        var start = max(currentTime, range.lowerBound)
        if start >= range.upperBound - 0.05 {
            start = range.lowerBound
        }
        currentTime = start
        startSynced(from: start)
        setPlaying(true)
    }

    func pause() {
        guard isPlaying else { return }
        let now = tutorialPlayer.currentTime().seconds
        tutorialPlayer.pause()
        takePlayer.pause()
        setPlaying(false)
        // Park both videos on the exact same frame time.
        seekPrecisely(to: now.isFinite ? clampToRange(now) : currentTime)
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    // MARK: - Moving around

    /// Jumps to a tutorial time (both videos, exact). Keeps playing if it was playing.
    func seek(to tutorialTime: Double) {
        guard isReady else { return }
        let target = clampToRange(tutorialTime)
        if isPlaying {
            currentTime = target
            startSynced(from: target)
        } else {
            seekPrecisely(to: target)
        }
    }

    /// Pauses and moves one frame forward (+1) or back (-1) at 30 fps.
    func stepFrames(_ count: Int) {
        guard isReady, count != 0 else { return }
        pause()
        // Snap to the frame grid so repeated steps never drift.
        let frame = (currentTime * Self.stepFPS).rounded()
        seekPrecisely(to: clampToRange((frame + Double(count)) / Self.stepFPS))
    }

    /// Changes the speed (e.g. 0.5). The take follows automatically.
    func setRate(_ newRate: Float) {
        guard newRate > 0 else { return }
        rate = newRate
        if isPlaying {
            resyncFromPlayerTime()
        }
    }

    /// Fine-tunes the sync by `delta` seconds of take time and shows the
    /// result right away. The caller saves the model context.
    func applyNudge(_ delta: Double) {
        let raw = takeModel.syncNudge + delta
        // Round to milliseconds so repeated steps don't collect float noise.
        let value = min(max((raw * 1000).rounded() / 1000, -5), 5)
        takeModel.syncNudge = value
        nudge = value
        if isPlaying {
            resyncFromPlayerTime()
        } else {
            seekPrecisely(to: currentTime)
        }
    }

    // MARK: - Time math

    private func cmTime(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: Self.timeScale)
    }

    private func clampToRange(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return range.lowerBound }
        return min(max(seconds, range.lowerBound), range.upperBound)
    }

    /// Where the take should be for tutorial time `t` (may be negative or too large).
    private func rawTakeTime(for tutorialTime: Double) -> Double {
        takeModel.timing.takeTime(forTutorialTime: tutorialTime)
    }

    /// The same, kept inside the take (it then just shows its first/last frame).
    private func clampedTakeTime(for tutorialTime: Double) -> Double {
        let low = max(rawTakeTime(for: tutorialTime), 0)
        return takeDuration > 0 ? min(low, takeDuration) : low
    }

    // MARK: - Synchronized start

    /// Starts both players so that tutorial time `tutorialTime` happens at the
    /// same moment on the device clock for both videos.
    private func startSynced(from tutorialTime: Double) {
        // Forget any running chase seek: setRate(time:) replaces it.
        seekGeneration += 1
        isSeekInProgress = false

        let lead = 0.08  // a little head start so both players can prepare
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        let host = CMTimeAdd(hostNow, cmTime(lead))

        let timing = takeModel.timing
        let takeRate = Float(timing.takeRate(forTutorialRate: Double(rate)))
        let rawTake = timing.takeTime(forTutorialTime: tutorialTime)

        tutorialPlayer.setRate(rate, time: cmTime(tutorialTime), atHostTime: host)

        if rawTake < 0 {
            // Your recording hasn't started yet at this tutorial time: let it
            // begin from its first frame at exactly the right moment.
            let wait = -rawTake / Double(takeRate)
            takePlayer.setRate(takeRate, time: .zero, atHostTime: CMTimeAdd(host, cmTime(wait)))
        } else if takeDuration > 0, rawTake >= takeDuration {
            // Your recording is already over: hold its last frame.
            takePlayer.pause()
            takePlayer.seek(to: cmTime(takeDuration), toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            takePlayer.setRate(takeRate, time: cmTime(rawTake), atHostTime: host)
        }

        let now = CACurrentMediaTime()
        settleUntil = now + lead + 0.25
        lastDriftCheck = now
        lastResync = now
    }

    /// Re-syncs from wherever the tutorial really is right now.
    private func resyncFromPlayerTime() {
        let now = tutorialPlayer.currentTime().seconds
        let t = now.isFinite ? clampToRange(now) : currentTime
        currentTime = t
        startSynced(from: t)
    }

    // MARK: - Precise seeking (both players)

    private func seekPrecisely(to tutorialTime: Double) {
        guard tutorialPlayer.currentItem != nil, takePlayer.currentItem != nil else { return }
        currentTime = tutorialTime
        chaseTime = tutorialTime
        chaseVersion += 1
        if !isSeekInProgress {
            startChaseSeek()
        }
    }

    private func startChaseSeek() {
        isSeekInProgress = true
        pendingSeeks = 2
        let target = chaseTime
        let version = chaseVersion
        let generation = seekGeneration

        let done: @Sendable (Bool) -> Void = { [weak self] _ in
            // AVFoundation may call this on any thread: hop to the main actor.
            guard let self else { return }
            Task { @MainActor in
                self.seekPartFinished(version: version, generation: generation)
            }
        }
        tutorialPlayer.seek(to: cmTime(target), toleranceBefore: .zero, toleranceAfter: .zero,
                            completionHandler: done)
        takePlayer.seek(to: cmTime(clampedTakeTime(for: target)), toleranceBefore: .zero,
                        toleranceAfter: .zero, completionHandler: done)
    }

    /// Called once per player when its seek is done.
    private func seekPartFinished(version: Int, generation: Int) {
        guard generation == seekGeneration else { return }
        pendingSeeks -= 1
        guard pendingSeeks <= 0 else { return }
        if version == chaseVersion {
            isSeekInProgress = false
        } else {
            // Asked for something newer while seeking: go there now.
            startChaseSeek()
        }
    }

    // MARK: - Observers

    private func installObserversIfNeeded() {
        if timeObserver == nil {
            let interval = CMTime(value: 1, timescale: 30)
            timeObserver = tutorialPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                guard let self else { return }
                // We asked for the main queue, so we are on the main actor.
                MainActor.assumeIsolated {
                    self.handleTick(time)
                }
            }
        }
        if endObserver == nil, let item = tutorialPlayer.currentItem {
            endObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification,
                object: item,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.handleRangeEnd()
                }
            }
        }
    }

    private func removeObservers() {
        if let token = timeObserver {
            tutorialPlayer.removeTimeObserver(token)
        }
        timeObserver = nil
        if let token = endObserver {
            NotificationCenter.default.removeObserver(token)
        }
        endObserver = nil
    }

    // MARK: - Ticks, looping, drift

    /// Called ~30x per second.
    private func handleTick(_ time: CMTime) {
        guard isPlaying, !isSeekInProgress else { return }
        let now = CACurrentMediaTime()
        // Right after a (re)start the players report in-between times; ignore them.
        guard now >= settleUntil else { return }
        let seconds = time.seconds
        guard seconds.isFinite else { return }

        currentTime = clampToRange(seconds)
        if seconds >= range.upperBound {
            handleRangeEnd()
            return
        }
        checkDrift(tutorialSeconds: seconds, now: now)
    }

    /// Reached the end of the range (or of the tutorial video).
    private func handleRangeEnd() {
        guard isPlaying else { return }
        if isLooping {
            currentTime = range.lowerBound
            startSynced(from: range.lowerBound)
        } else {
            tutorialPlayer.pause()
            takePlayer.pause()
            setPlaying(false)
            seekPrecisely(to: range.upperBound)
        }
    }

    /// About twice a second: if the take has slipped away from where it
    /// should be, start both again on a fresh shared clock time.
    private func checkDrift(tutorialSeconds: Double, now: CFTimeInterval) {
        guard now - lastDriftCheck >= 0.5 else { return }
        lastDriftCheck = now
        guard now - lastResync >= 1.0 else { return }

        let expected = rawTakeTime(for: tutorialSeconds)
        // Not started yet, or already at its end: nothing to compare.
        guard expected >= 0 else { return }
        if takeDuration > 0, expected >= takeDuration - 0.1 { return }

        let actual = takePlayer.currentTime().seconds
        guard actual.isFinite else { return }
        if abs(actual - expected) > 0.05 {
            resyncFromPlayerTime()
        }
    }

    /// Updates `isPlaying` and keeps the screen awake while playing.
    private func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        UIApplication.shared.isIdleTimerDisabled = playing
    }
}
