import AVFoundation
import Foundation
import Observation

/// Sounds that help you dance along on the practice screen:
///
/// - **Count-in**: "5, 6, 7, 8" in the song's tempo before the video starts.
/// - **Beat click**: a tick on every beat (a brighter one on count 1).
/// - **Say the counts**: a voice says "1, 2, 3 … 8" on the beats.
/// - **Say my moves**: on count 5 a voice reads the note of the NEXT 8-count
///   ("turn left, hit"), so you hear what's coming before it comes.
/// - **Fade as I repeat**: while a part loops, every run is quieter than the
///   one before; after four runs the cues are silent and you're on your own.
///
/// The beats are scheduled a moment ahead on the audio clock
/// (`AVAudioPlayerNode` + host time), so they land on the beat instead of
/// "whenever a timer fires". The spoken numbers are made once with the
/// iPhone's own voice (`AVSpeechSynthesizer.write`) and then played like
/// sound files. Move names are spoken live (they change all the time).
@MainActor
@Observable
final class CountCues: CountInProvider {

    struct Settings: Equatable {
        var countIn = false
        /// Count in again each time a loop starts over.
        var countInEveryLoop = false
        var click = false
        var sayCounts = false
        var sayMoves = false
        var fade = false

        /// True when anything plays while the video runs.
        var duringPlayback: Bool { click || sayCounts || sayMoves }
        var anything: Bool { countIn || duringPlayback }
    }

    /// How loud the cues are right now (1 = full, 0 = faded out).
    private(set) var level: Float = 1

    /// Whether the spoken numbers are ready (shown in the Practice sheet).
    enum VoiceStatus: Equatable {
        case notLoaded, loading, ready, unavailable
    }
    private(set) var voiceStatus: VoiceStatus = .notLoaded

    @ObservationIgnored private var settings = Settings()
    @ObservationIgnored private var grid = CountGrid(bpm: 0, offset: 0, duration: 0)
    @ObservationIgnored private weak var controller: PlayerController?
    /// The note text for an 8-count (for "Say my moves").
    @ObservationIgnored private var moveText: (Int) -> String? = { _ in nil }

    @ObservationIgnored private let engine = AVAudioEngine()
    /// Two players, so the click and the voice can have their own volume.
    @ObservationIgnored private let clickNode = AVAudioPlayerNode()
    @ObservationIgnored private let voiceNode = AVAudioPlayerNode()
    @ObservationIgnored private var engineReady = false
    /// "1"…"8", "5"…"8" for the count-in, plus "tick" and "accent".
    @ObservationIgnored private var clips: [String: AVAudioPCMBuffer] = [:]
    @ObservationIgnored private var voiceLoading = false
    @ObservationIgnored private let speaker = AVSpeechSynthesizer()

    @ObservationIgnored private var timer: Timer?
    /// The beat (counted from count 1 of the first 8-count) that was last
    /// scheduled, so each beat is played once.
    @ObservationIgnored private var lastBeat: Int?
    /// Fade bookkeeping: the loop's wrap count when the current loop began.
    @ObservationIgnored private var fadeStartWraps = 0
    @ObservationIgnored private var fadeLoop: ClosedRange<Double>?

    /// Clips are made in this format (mono, 44.1 kHz, float).
    private static let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    /// How far ahead a beat is scheduled.
    private static let lookahead: Double = 0.15
    /// Each loop run makes the cues this much quieter (with "Fade").
    private static let fadeStep: Float = 0.25

    init() {}

    // MARK: - Setup

    /// Call when the practice screen appears.
    func start(controller: PlayerController) {
        self.controller = controller
        controller.countIn = self
        guard timer == nil else { return }
        // 60×/s is plenty to schedule 150 ms ahead, and very cheap.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Call when the practice screen goes away.
    func stop() {
        timer?.invalidate()
        timer = nil
        cancelCountIn()
        speaker.stopSpeaking(at: .immediate)
        if engineReady {
            clickNode.stop()
            voiceNode.stop()
            engine.stop()
        }
        if controller?.countIn === self { controller?.countIn = nil }
    }

    /// New settings / tempo / notes from the screen.
    func update(settings: Settings, grid: CountGrid, moveText: @escaping (Int) -> String?) {
        let changed = settings != self.settings
        self.settings = settings
        self.grid = grid
        self.moveText = moveText
        if changed {
            lastBeat = nil
            if !settings.fade { level = 1 }
            if !settings.duringPlayback { speaker.stopSpeaking(at: .word) }
        }
        if settings.anything { prepare() }
    }

    // MARK: - Count-in (CountInProvider)

    func startCountIn(rate: Float) -> TimeInterval {
        guard settings.countIn, grid.isValid, rate > 0 else { return 0 }
        prepare()
        guard engineReady else { return 0 }
        let beat = grid.beatDuration / Double(rate)
        let lead = 0.12
        for (i, word) in ["5", "6", "7", "8"].enumerated() {
            let delay = lead + Double(i) * beat
            // The count-in is never faded: it's your cue to start.
            if let clip = clips["in\(word)"] {
                play(clip, on: voiceNode, after: delay, volume: 1)
            } else if let clip = clips[i == 0 ? "accent" : "tick"] {
                play(clip, on: clickNode, after: delay, volume: 1)
            }
        }
        lastBeat = nil
        return lead + 4 * beat
    }

    func cancelCountIn() {
        guard engineReady else { return }
        for node in [clickNode, voiceNode] {
            node.stop()          // drops everything still scheduled
            if engine.isRunning { node.play() }
        }
        lastBeat = nil
    }

    // MARK: - Beats while playing

    private func tick() {
        guard let controller else { return }
        updateFade(controller)
        guard settings.duringPlayback, grid.isValid, controller.isPlaying, !controller.isCountingIn,
              level > 0.01 else {
            lastBeat = nil
            return
        }
        let player = controller.player
        let rate = Double(player.rate)
        let now = player.currentTime().seconds
        guard rate > 0, now.isFinite else { return }

        let beatLength = grid.beatDuration
        let position = (now - grid.offset) / beatLength
        let current = Int(floor(position + 1e-6))

        // Jumped (seek, loop restart, 8-count tap): start counting afresh.
        // If we landed right on a beat (loops start on count 1), play it now.
        if let last = lastBeat, current + 1 < last || current > last + 1 {
            lastBeat = nil
        }
        if lastBeat == nil {
            let sinceBeat = (now - beatTime(current)) / rate
            if sinceBeat >= 0, sinceBeat < 0.06 {
                playBeat(current, after: 0)
            }
            lastBeat = current
        }

        let next = current + 1
        guard let last = lastBeat, next > last else { return }
        let time = beatTime(next)
        // Past B the loop jumps back to A: that beat never comes.
        if controller.isLooping, let end = controller.loopEnd, time >= end - 0.02 { return }
        let wait = (time - now) / rate
        guard wait <= Self.lookahead else { return }
        playBeat(next, after: max(wait, 0))
        lastBeat = next
    }

    private func beatTime(_ beat: Int) -> Double {
        grid.offset + Double(beat) * grid.beatDuration
    }

    /// Plays the cues for beat number `beat` (0 = count 1 of the first 8-count).
    private func playBeat(_ beat: Int, after delay: Double) {
        prepare()
        let count = ((beat % 8) + 8) % 8 + 1          // 1…8 (also in the intro)
        let tick = clips[count == 1 ? "accent" : "tick"]
        var spoke = false
        // While a move name is being said, the numbers step aside (ticks stay).
        if settings.sayCounts, !speaker.isSpeaking, let clip = clips["\(count)"] {
            play(clip, on: voiceNode, after: delay, volume: level)
            spoke = true
        }
        if settings.click || (settings.sayCounts && !spoke), let tick {
            play(tick, on: clickNode, after: delay, volume: level * (spoke ? 0.5 : 1))
        }

        // On count 5, say what's next.
        if settings.sayMoves, count == 5, beat >= 0 {
            let eightCount = beat / 8
            if let text = moveText(eightCount + 1).map(Self.shortMove), !text.isEmpty {
                let utterance = AVSpeechUtterance(string: text)
                utterance.rate = 0.56
                utterance.volume = level
                utterance.preUtteranceDelay = max(delay, 0)
                speaker.stopSpeaking(at: .immediate)
                speaker.speak(utterance)
            }
        }
    }

    /// First line of a note, at most ~6 words, so it fits in four counts.
    private static func shortMove(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let words = line.split(separator: " ").prefix(6)
        return words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Fade

    private func updateFade(_ controller: PlayerController) {
        guard settings.fade else { return }
        guard controller.isLooping, let a = controller.loopStart, let b = controller.loopEnd else {
            fadeLoop = nil
            if level != 1 { level = 1 }
            return
        }
        let loop = a...b
        if fadeLoop != loop {
            // A new part is looping: start loud again.
            fadeLoop = loop
            fadeStartWraps = controller.loopWraps
        }
        let runs = controller.loopWraps - fadeStartWraps
        let newLevel = max(0, 1 - Float(runs) * Self.fadeStep)
        if newLevel != level { level = newLevel }
    }

    // MARK: - Audio plumbing

    /// Starts the audio engine and loads the sounds (once).
    private func prepare() {
        if !engineReady {
            for node in [clickNode, voiceNode] {
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: Self.format)
            }
            engine.prepare()
            engineReady = true
            clips["tick"] = Self.loadClip(named: "countdown-tick")
            clips["accent"] = Self.loadClip(named: "countdown-go")
        }
        if !engine.isRunning {
            // Also after a phone call / headphones change stopped the engine.
            do {
                try engine.start()
                clickNode.play()
                voiceNode.play()
            } catch {
                return
            }
        }
        if !voiceLoading {
            voiceLoading = true
            voiceStatus = .loading
            Task { await loadVoice() }
        }
    }

    private func play(_ clip: AVAudioPCMBuffer, on node: AVAudioPlayerNode, after delay: Double, volume: Float) {
        guard engineReady, engine.isRunning else { return }
        if !node.isPlaying { node.play() }
        node.volume = volume
        let host = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: max(delay, 0))
        node.scheduleBuffer(clip, at: AVAudioTime(hostTime: host), options: [], completionHandler: nil)
    }

    /// Makes the spoken numbers with the iPhone's voice (in the background,
    /// ~1 s). Until they're ready, ticks are used instead.
    private func loadVoice() async {
        let words = ["one", "two", "three", "four", "five", "six", "seven", "eight"]
        let renderer = AVSpeechSynthesizer()
        for (i, word) in words.enumerated() {
            guard let raw = await Self.render(word, with: renderer, rate: 0.6),
                  let clip = Self.trimmed(raw) else { continue }
            clips["\(i + 1)"] = clip
        }
        // Count-in: a bit louder and slower, like a teacher calling it.
        for (i, word) in ["five", "six", "seven", "eight"].enumerated() {
            guard let raw = await Self.render(word, with: renderer, rate: 0.5),
                  let clip = Self.trimmed(raw) else { continue }
            clips["in\(i + 5)"] = clip
        }
        voiceStatus = (1...8).allSatisfy { clips["\($0)"] != nil } ? .ready : .unavailable
    }

    private static func loadClip(named name: String) -> AVAudioPCMBuffer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav"),
              let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil else { return nil }
        return convertForCollector(buffer)
    }

    /// Speaks `text` into a buffer instead of out loud. Nonisolated: the
    /// synthesizer calls back on its own thread.
    nonisolated private static func render(_ text: String, with synthesizer: AVSpeechSynthesizer,
                               rate: Float) async -> AVAudioPCMBuffer? {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = rate
        if let voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode()) {
            utterance.voice = voice
        }
        let collector = BufferCollector()
        return await withCheckedContinuation { continuation in
            collector.onFinish = { continuation.resume(returning: $0) }
            synthesizer.write(utterance) { buffer in
                collector.add(buffer as? AVAudioPCMBuffer)
            }
            // Some iOS versions never send the final empty buffer: don't wait forever.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { collector.finish() }
        }
    }

    /// Cuts the silence before and after a spoken word, so it starts right on the beat.
    private static func trimmed(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return nil }
        let count = Int(buffer.frameLength)
        let threshold: Float = 0.02
        guard let first = (0..<count).first(where: { abs(data[$0]) > threshold }),
              let last = (0..<count).last(where: { abs(data[$0]) > threshold }) else { return nil }
        let start = max(first - 200, 0)                 // keep ~5 ms before the sound
        let end = min(last + 2_000, count - 1)          // and a short tail
        let length = AVAudioFrameCount(end - start + 1)
        guard let output = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: length),
              let target = output.floatChannelData?[0] else { return nil }
        output.frameLength = length
        target.update(from: data + start, count: Int(length))
        return output
    }
}

/// Collects the pieces `AVSpeechSynthesizer.write` hands out (on its own
/// thread) and joins them into one buffer when the word is done.
private final class BufferCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var pieces: [AVAudioPCMBuffer] = []
    private var finished = false
    var onFinish: ((AVAudioPCMBuffer?) -> Void)?

    func add(_ buffer: AVAudioPCMBuffer?) {
        guard let buffer else { return }
        if buffer.frameLength == 0 {
            finish()
            return
        }
        guard let converted = CountCues.convertForCollector(buffer) else { return }
        lock.lock()
        if !finished { pieces.append(converted) }
        lock.unlock()
    }

    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let parts = pieces
        let callback = onFinish
        onFinish = nil
        lock.unlock()
        callback?(Self.join(parts))
    }

    private static func join(_ parts: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let format = parts.first?.format else { return nil }
        let total = parts.reduce(0) { $0 + $1.frameLength }
        guard total > 0, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total),
              let target = output.floatChannelData?[0] else { return nil }
        var position = 0
        for part in parts {
            guard let source = part.floatChannelData?[0] else { continue }
            (target + position).update(from: source, count: Int(part.frameLength))
            position += Int(part.frameLength)
        }
        output.frameLength = AVAudioFrameCount(position)
        return output
    }
}

extension CountCues {
    /// Copies `buffer` (the synthesizer may reuse its own) and converts it to
    /// mono 44.1 kHz float. Safe on any thread: it only touches that buffer.
    nonisolated fileprivate static func convertForCollector(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        // Copy first: the synthesizer may reuse its buffer after the callback.
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for c in 0..<channels { dst[c].update(from: src[c], count: frames) }
        } else if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            for c in 0..<channels { dst[c].update(from: src[c], count: frames) }
        } else if let src = buffer.int32ChannelData, let dst = copy.int32ChannelData {
            for c in 0..<channels { dst[c].update(from: src[c], count: frames) }
        } else {
            return nil
        }
        return convertAnyThread(copy)
    }

    nonisolated private static func convertAnyThread(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else { return nil }
        if buffer.format == format { return buffer }
        guard buffer.frameLength > 0,
              let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }
}
