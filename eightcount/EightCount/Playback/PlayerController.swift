import AVFoundation
import Observation
import UIKit

/// Owns the AVPlayer and everything the playback screen needs to know:
/// current time, play/pause, speed, mirroring and the A-B loop.
///
/// Views read its properties directly; thanks to `@Observable`, SwiftUI
/// redraws a view automatically when a property it reads changes.
///
/// Call `tearDown()` from `.onDisappear` so observers are removed and the
/// screen is allowed to sleep again.
@MainActor
@Observable
final class PlayerController {
    // MARK: - State the UI reads

    /// The underlying AVFoundation player (shown by `VideoSurface`).
    let player: AVPlayer

    /// True once a video is loaded and ready to show.
    private(set) var isReady = false
    /// True while the video is playing (or buffering to play).
    private(set) var isPlaying = false
    /// Playhead position in seconds.
    private(set) var currentTime: Double = 0
    /// Video length in seconds (0 until loaded).
    private(set) var duration: Double = 0
    /// Frames per second of the video track (used for frame stepping).
    private(set) var frameRate: Double = 30
    /// Width / height as the video is *displayed* (phone videos shot in
    /// portrait give a value below 1).
    private(set) var videoAspectRatio: CGFloat = 16.0 / 9.0
    /// Playback speed, e.g. 0.5 = half speed.
    private(set) var rate: Float = 1.0
    /// Flip the picture left-right, like looking in a mirror.
    var isMirrored = false

    /// Loop start ("A") in seconds.
    private(set) var loopStart: Double? = nil
    /// Loop end ("B") in seconds.
    private(set) var loopEnd: Double? = nil
    /// The loop switch. Only has an effect when A and B are both set.
    var isLoopEnabled = false
    /// Which 8-count (0-based) is being looped, if the loop came from
    /// `loopEightCount(...)`. Cleared when A/B are changed by hand.
    private(set) var loopedEightCount: Int? = nil
    /// Counts how often the loop jumped from B back to A (one finished run).
    /// The practice coach watches it to move on after enough runs.
    private(set) var loopWraps = 0

    /// True while the video plays on a TV via AirPlay (the phone is the remote).
    private(set) var isOnTV = false

    /// True during the "5, 6, 7, 8" before the video starts.
    private(set) var isCountingIn = false
    /// Plays the count-in sounds (set by the practice screen when the
    /// count-in is switched on). Nil = no count-in.
    @ObservationIgnored weak var countIn: CountInProvider?
    /// Also count in each time the loop starts over (not only on Play).
    @ObservationIgnored var countInOnLoop = false
    @ObservationIgnored private var countInTask: Task<Void, Never>?

    /// A readable error if the video could not be opened.
    private(set) var loadError: String? = nil

    /// True when the A-B loop is actually active.
    var isLooping: Bool {
        guard isLoopEnabled, let start = loopStart, let end = loopEnd else { return false }
        return end > start
    }

    /// The speeds offered in the UI.
    nonisolated static let speeds: [Float] = [0.25, 0.5, 0.75, 1.0, 2.0]

    // MARK: - Private bookkeeping (not observed by SwiftUI)

    /// Token from `addPeriodicTimeObserver`, needed to remove it again.
    @ObservationIgnored private var timeObserver: Any? = nil
    /// Watches `player.timeControlStatus` (playing / paused).
    @ObservationIgnored private var statusObservation: NSKeyValueObservation? = nil
    /// Watches `player.isExternalPlaybackActive` (AirPlay to a TV).
    @ObservationIgnored private var tvObservation: NSKeyValueObservation? = nil
    /// Token for the "video reached its end" notification.
    @ObservationIgnored private var endObserver: NSObjectProtocol? = nil

    /// "Chase time" seeking: while one precise seek is running we only
    /// remember the newest target and jump there when the running seek is
    /// done. Without this, fast scrubbing queues up dozens of slow seeks.
    @ObservationIgnored private var isSeekInProgress = false
    @ObservationIgnored private var chaseTarget: CMTime = .zero
    /// Bumped when a new video is loaded so old seek callbacks are ignored.
    @ObservationIgnored private var seekGeneration = 0
    /// Bumped on every `load(url:)` so a slow, older load can't win.
    @ObservationIgnored private var loadGeneration = 0
    /// Set when the video played to the very end (so Play restarts at 0).
    @ObservationIgnored private var reachedEnd = false

    /// Fine-grained time scale for seeks (60 000 ticks per second) so
    /// frame times like 1/30 s or 1/60 s are represented exactly.
    private static let timeScale: CMTimeScale = 60_000

    // MARK: - Setup

    init() {
        player = AVPlayer()
        // At the end of the video just stop (we handle looping ourselves).
        player.actionAtItemEnd = .pause
        // AirPlay: send the video itself to the TV (not a mirror of the screen).
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        // Observers are added in `load(url:)`, not here: SwiftUI may create
        // (and throw away) extra controllers, so `init` should stay cheap.
    }

    /// Opens a video file. Replaces whatever was loaded before.
    func load(url: URL) async {
        loadGeneration += 1
        let generation = loadGeneration

        player.pause()
        isReady = false
        loadError = nil
        currentTime = 0
        duration = 0
        reachedEnd = false
        clearLoop()

        // Play sound even when the ring/silent switch is on silent.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)

        let asset = AVURLAsset(url: url)
        do {
            // Read the video's properties with the modern async API.
            let loadedDuration = try await asset.load(.duration)
            var fps: Double = 30
            var aspect: CGFloat = 16.0 / 9.0
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let size = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let nominalFPS = try await track.load(.nominalFrameRate)

                // Phones store portrait videos as landscape pixels plus a
                // "rotate 90°" transform. Apply it to get the shown size.
                let shown = CGRect(origin: .zero, size: size).applying(transform)
                let width = abs(shown.width)
                let height = abs(shown.height)
                if width > 0, height > 0 {
                    aspect = width / height
                }
                if nominalFPS > 0 {
                    fps = Double(nominalFPS)
                }
            }

            // Another video was requested while we were loading: give up.
            guard generation == loadGeneration else { return }

            let item = AVPlayerItem(asset: asset)
            // Keeps the music's pitch normal when playing slower.
            item.audioTimePitchAlgorithm = .spectral

            removeEndObserver()
            seekGeneration += 1
            isSeekInProgress = false
            player.replaceCurrentItem(with: item)
            // `defaultRate` is the speed `play()` uses.
            player.defaultRate = rate
            installObserversIfNeeded()

            let seconds = loadedDuration.seconds
            duration = seconds.isFinite ? max(seconds, 0) : 0
            frameRate = fps
            videoAspectRatio = aspect
            currentTime = 0
            isReady = true
        } catch {
            guard generation == loadGeneration else { return }
            loadError = error.localizedDescription
        }
    }

    /// Removes observers, pauses and lets the screen sleep again.
    /// Call from `.onDisappear`. (Observers come back automatically on the
    /// next load, play or seek, so it is safe if the view reappears.)
    func tearDown() {
        cancelCountIn()
        if let token = timeObserver {
            player.removeTimeObserver(token)
        }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        tvObservation?.invalidate()
        tvObservation = nil
        removeEndObserver()
        player.pause()
        setPlaying(false)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Play / pause

    /// Starts playing. With a count-in set up (`countIn`), "5, 6, 7, 8" is
    /// heard first and the video starts right after it. `countIn: false`
    /// skips it (e.g. when you let go of the scrubber).
    func play(countIn: Bool = true) {
        guard isReady, player.currentItem != nil else { return }
        installObserversIfNeeded()
        cancelCountIn()

        if isLooping, let start = loopStart, let end = loopEnd, currentTime >= end - 0.001 {
            // Paused at (or past) B: start the loop again from A.
            seekPrecisely(to: start)
        } else if !isLooping, reachedEnd || (duration > 0 && currentTime >= duration - 0.001) {
            // The video had finished: start over from the beginning.
            seekPrecisely(to: 0)
        }

        let wait = countIn ? (self.countIn?.startCountIn(rate: rate) ?? 0) : 0
        guard wait > 0 else {
            startPlayer()
            return
        }
        waitThenPlay(wait)
    }

    /// Plays after `wait` seconds (while the count-in sounds).
    private func waitThenPlay(_ wait: TimeInterval) {
        isCountingIn = true
        countInTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            self.isCountingIn = false
            self.countInTask = nil
            self.startPlayer()
        }
    }

    private func startPlayer() {
        player.defaultRate = rate
        player.play()
    }

    func pause() {
        cancelCountIn()
        player.pause()
    }

    /// Stops a running count-in (and its sounds).
    private func cancelCountIn() {
        guard isCountingIn || countInTask != nil else { return }
        countInTask?.cancel()
        countInTask = nil
        isCountingIn = false
        countIn?.cancelCountIn()
    }

    func togglePlayPause() {
        if isPlaying || isCountingIn {
            pause()
        } else {
            play()
        }
    }

    // MARK: - Moving around

    /// Jumps to an exact time. If this leaves the A-B range while the loop
    /// is on, the loop is switched off (A and B are kept).
    func seek(to seconds: Double) {
        let target = clamped(seconds)
        if isLooping, let start = loopStart, let end = loopEnd,
           target < start - 0.001 || target > end + 0.001 {
            isLoopEnabled = false
            loopedEightCount = nil
        }
        seekPrecisely(to: target)
    }

    /// Pauses and moves `count` frames forward (positive) or back (negative).
    func stepFrames(_ count: Int) {
        guard isReady, count != 0 else { return }
        pause()
        let fps = frameRate > 0 ? frameRate : 30
        // Snap to the frame grid so repeated steps never drift.
        let currentFrame = (currentTime * fps).rounded()
        seekPrecisely(to: (currentFrame + Double(count)) / fps)
    }

    /// Jumps forward (positive) or back (negative) by some seconds.
    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    /// Changes playback speed (e.g. 0.5 for half speed).
    func setRate(_ newRate: Float) {
        rate = newRate
        player.defaultRate = newRate
        if player.timeControlStatus != .paused {
            player.rate = newRate
        }
    }

    // MARK: - A-B loop

    /// Marks the current time as loop start.
    func setA() {
        loopStart = currentTime
        loopedEightCount = nil
        orderLoopPointsAndEnable()
    }

    /// Marks the current time as loop end.
    func setB() {
        loopEnd = currentTime
        loopedEightCount = nil
        orderLoopPointsAndEnable()
    }

    /// Turns the loop on/off. When turning on while outside A-B, jumps to A.
    func toggleLoop() {
        isLoopEnabled.toggle()
        if isLooping, let start = loopStart, let end = loopEnd,
           currentTime < start || currentTime > end {
            seekPrecisely(to: start)
        }
    }

    /// Loops one 8-count: sets A/B to its range and jumps to its start.
    func loopEightCount(_ index: Int, start: Double, end: Double) {
        let a = clamped(min(start, end))
        let b = clamped(max(start, end))
        loopStart = a
        loopEnd = b
        isLoopEnabled = true
        loopedEightCount = index
        seekPrecisely(to: a)
    }

    /// Loops a stretch of several 8-counts (or any range): sets A/B and
    /// jumps to A. `loopedEightCount` stays nil.
    func loopSpan(start: Double, end: Double) {
        let a = clamped(min(start, end))
        let b = clamped(max(start, end))
        loopStart = a
        loopEnd = b
        isLoopEnabled = true
        loopedEightCount = nil
        seekPrecisely(to: a)
    }

    /// Removes A and B and switches the loop off.
    func clearLoop() {
        loopStart = nil
        loopEnd = nil
        loopedEightCount = nil
        isLoopEnabled = false
    }

    // MARK: - Private helpers

    /// When both points exist: make sure A comes before B and enable the loop.
    private func orderLoopPointsAndEnable() {
        guard let start = loopStart, let end = loopEnd else { return }
        if end < start {
            loopStart = end
            loopEnd = start
        }
        isLoopEnabled = true
    }

    /// Keeps a time inside 0...duration.
    private func clamped(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        let positive = max(seconds, 0)
        return duration > 0 ? min(positive, duration) : positive
    }

    /// Exact seek (no tolerance) using the "chase time" pattern.
    /// Updates `currentTime` right away so the UI feels instant.
    private func seekPrecisely(to seconds: Double) {
        guard player.currentItem != nil else { return }
        let target = clamped(seconds)
        reachedEnd = false
        currentTime = target
        chaseTarget = CMTime(seconds: target, preferredTimescale: Self.timeScale)
        installObserversIfNeeded()
        if !isSeekInProgress {
            startChaseSeek()
        }
    }

    private func startChaseSeek() {
        isSeekInProgress = true
        let target = chaseTarget
        let generation = seekGeneration
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            // AVFoundation may call this on any thread: hop to the main actor.
            guard let self else { return }
            Task { @MainActor in
                self.chaseSeekFinished(target: target, generation: generation)
            }
        }
    }

    private func chaseSeekFinished(target: CMTime, generation: Int) {
        // A new video was loaded meanwhile; this seek no longer matters.
        guard generation == seekGeneration else { return }
        if CMTimeCompare(target, chaseTarget) == 0 {
            isSeekInProgress = false
        } else {
            // The user moved on while we were seeking: go to the newest spot.
            startChaseSeek()
        }
    }

    /// Adds the time / status / end-of-video observers if they're missing.
    private func installObserversIfNeeded() {
        if timeObserver == nil {
            // ~60 updates per second while playing (plus one after each seek).
            let interval = CMTime(value: 1, timescale: 60)
            timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                guard let self else { return }
                // We asked for the main queue, so we are on the main actor.
                MainActor.assumeIsolated {
                    self.handleTick(time)
                }
            }
        }

        if statusObservation == nil {
            statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                let status = player.timeControlStatus
                guard let self else { return }
                Task { @MainActor in
                    self.setPlaying(status != .paused)
                }
            }
        }

        if tvObservation == nil {
            tvObservation = player.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self] player, _ in
                let active = player.isExternalPlaybackActive
                guard let self else { return }
                Task { @MainActor in
                    if self.isOnTV != active { self.isOnTV = active }
                }
            }
        }

        if endObserver == nil, let item = player.currentItem {
            endObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification,
                object: item,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.handleDidPlayToEnd()
                }
            }
        }
    }

    private func removeEndObserver() {
        if let token = endObserver {
            NotificationCenter.default.removeObserver(token)
        }
        endObserver = nil
    }

    /// Called ~60x per second while playing.
    private func handleTick(_ time: CMTime) {
        // While a seek is running, `currentTime` already shows the target;
        // don't let in-between times make the slider jump around.
        guard !isSeekInProgress else { return }
        let seconds = time.seconds
        guard seconds.isFinite else { return }
        currentTime = seconds

        // A-B loop: passed B while playing → jump back to A, keep playing.
        if isLooping, player.timeControlStatus != .paused,
           let start = loopStart, let end = loopEnd, seconds >= end {
            loopWraps += 1
            if countInBeforeRestart() {
                player.pause()
                seekPrecisely(to: start)
                return
            }
            seekPrecisely(to: start)
        }
    }

    private func handleDidPlayToEnd() {
        if isLooping, let start = loopStart {
            // B was at (or very near) the end of the video.
            loopWraps += 1
            seekPrecisely(to: start)
            if countInBeforeRestart() { return }
            player.play()
        } else {
            reachedEnd = true
            if duration > 0 {
                currentTime = duration
            }
            setPlaying(false)
        }
    }

    /// With "count-in every loop": starts the count-in and the wait, and
    /// returns true (the caller then pauses at A instead of playing on).
    private func countInBeforeRestart() -> Bool {
        guard countInOnLoop, let provider = countIn else { return false }
        let wait = provider.startCountIn(rate: rate)
        guard wait > 0 else { return false }
        waitThenPlay(wait)
        return true
    }

    /// Updates `isPlaying` and keeps the screen awake while playing.
    private func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        UIApplication.shared.isIdleTimerDisabled = playing
    }
}

/// Something that can play a count-in before the video starts.
@MainActor
protocol CountInProvider: AnyObject {
    /// Starts the count-in sounds and returns how many seconds they take
    /// (0 = no count-in right now). `rate` is the playback speed.
    func startCountIn(rate: Float) -> TimeInterval
    /// Silences a count-in that is still running.
    func cancelCountIn()
}
