import AVFoundation
import Accelerate
import Foundation

/// Finds a song's tempo (BPM) and where a bar starts, from the video's sound.
///
/// How (the usual "onset" method, all on the iPhone):
/// 1. Read the sound as mono, 22 050 samples per second.
/// 2. Cut it into short overlapping slices (1024 samples, every 256) and
///    measure how much *new* sound each slice has compared with the one
///    before ("spectral flux"). Drums and claps make spikes.
/// 3. Tempo: which beat length makes those spikes line up best (an
///    autocorrelation, with a gentle preference for 70–160 BPM to avoid
///    picking half or double tempo), then fine-tuned to 0.02 BPM by checking
///    how well an exact beat grid fits the whole song.
/// 4. Count 1: of the four beats in a bar, the one with the strongest hits
///    (downbeats are usually louder). This can be off by a beat or by four
///    counts – the tempo screen lets you shift it.
///
/// Tested on synthetic drum tracks (within ~10 ms); real songs with soft or
/// changing beats can fool it, so the screen asks you to check by ear.
enum BeatDetector {
    struct Result: Equatable {
        var bpm: Double
        /// Video time (s) of the first bar start ("count 1"), ≥ 0.
        var firstDownbeat: Double
        /// 0…1, how clearly the beat stood out. Noise scores ~0.47, a clear
        /// drum beat ~0.9; below 0.7 the screen says "not sure".
        var confidence: Double

        var isSure: Bool { confidence >= 0.7 }
    }

    enum DetectError: LocalizedError {
        case noAudio, unreadable, tooShort, noBeat

        var errorDescription: String? {
            switch self {
            case .noAudio: return "This video has no sound."
            case .unreadable: return "The sound of this video couldn't be read."
            case .tooShort: return "The video is too short to find the beat (needs about 6 seconds)."
            case .noBeat: return "No clear beat found. Tap along instead."
            }
        }
    }

    static let sampleRate = 22_050.0
    private static let frameSize = 1024
    private static let hop = 256

    /// Reads up to `maxSeconds` of the video's sound and finds the beat.
    /// Runs off the main thread.
    static func detect(url: URL, maxSeconds: Double = 180) async throws -> Result {
        let samples = try await readMono(url: url, maxSeconds: maxSeconds)
        return try await Task.detached(priority: .userInitiated) {
            try detect(samples: samples)
        }.value
    }

    // MARK: - Reading the sound

    static func readMono(url: URL, maxSeconds: Double) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw DetectError.noAudio
        }
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let length = min(duration.isFinite ? duration : maxSeconds, maxSeconds)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: length, preferredTimescale: 600))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw DetectError.unreadable }
        reader.add(output)
        guard reader.startReading() else { throw DetectError.unreadable }

        var samples: [Float] = []
        samples.reserveCapacity(Int(length * sampleRate) + 1)
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            let count = bytes / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            var chunk = [Float](repeating: 0, count: count)
            let status = chunk.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 4, destination: base)
            }
            if status == noErr { samples.append(contentsOf: chunk) }
        }
        if reader.status == .failed { throw DetectError.unreadable }
        return samples
    }

    // MARK: - The analysis (pure math, testable)

    static func detect(samples: [Float]) throws -> Result {
        guard samples.count > Int(sampleRate * 6) else { throw DetectError.tooShort }
        let env = onsetEnvelope(samples)
        let fps = sampleRate / Double(hop)
        guard env.count > Int(fps * 5), (env.max() ?? 0) > 0 else { throw DetectError.noBeat }

        // 1. Rough tempo from the autocorrelation (only the lags we need).
        let maxLag = min(Int(fps * 60 / 60 * 4) + 2, env.count - 1)
        var ac = [Double](repeating: 0, count: maxLag + 1)
        env.withUnsafeBufferPointer { e in
            for lag in 1...maxLag {
                var sum: Float = 0
                vDSP_dotpr(e.baseAddress!, 1, e.baseAddress! + lag, 1, &sum, vDSP_Length(e.count - lag))
                ac[lag] = Double(sum)
            }
        }
        var coarse = 120.0
        var bestScore = -Double.infinity
        var bpm = 60.0
        while bpm <= 200 {
            let lag = fps * 60 / bpm
            var score = 0.0
            for (multiple, weight) in [(1.0, 1.0), (2.0, 0.5), (4.0, 0.25)] {
                let l = lag * multiple
                if l < Double(maxLag) { score += weight * interpolate(ac, l) }
            }
            let prior = exp(-0.5 * pow(log2(bpm / 115) / 0.8, 2))
            score *= prior
            if score > bestScore {
                bestScore = score
                coarse = bpm
            }
            bpm += 0.5
        }

        // 2. Fine tempo + phase: the exact beat grid that fits the whole song best.
        var best = (score: -Double.infinity, bpm: coarse, phase: 0.0)
        var allScores: [Double] = []
        var candidate = coarse * 0.97
        while candidate <= coarse * 1.03 {
            let period = fps * 60 / candidate
            var phase = 0.0
            while phase < period {
                let score = comb(env, period: period, phase: phase) / (Double(env.count) / period)
                allScores.append(score)
                if score > best.score { best = (score, candidate, phase) }
                phase += 0.5
            }
            candidate += 0.02
        }
        let period = fps * 60 / best.bpm

        // 3. Count 1: the strongest of the four beats of a bar.
        var barPhase = best.phase
        var barBest = -Double.infinity
        for j in 0..<4 {
            let phase = best.phase + Double(j) * period
            let score = comb(env, period: period * 4, phase: phase)
            if score > barBest {
                barBest = score
                barPhase = phase
            }
        }
        let beat = 60 / best.bpm
        var first = (barPhase * Double(hop) + Double(frameSize) / 2) / sampleRate
        while first - 4 * beat >= 0 { first -= 4 * beat }

        // Confidence: how much the best grid beats an average grid.
        let mean = allScores.reduce(0, +) / Double(max(allScores.count, 1))
        let confidence = best.score > 0 ? max(0, min(1, (best.score - mean) / best.score)) : 0
        guard confidence >= 0.5 else { throw DetectError.noBeat }

        return Result(bpm: (best.bpm * 10).rounded() / 10, firstDownbeat: first, confidence: confidence)
    }

    /// "How much new sound" per slice, minus the local average, scaled to 0…1.
    static func onsetEnvelope(_ samples: [Float]) -> [Float] {
        let n = frameSize
        let half = n / 2
        let frames = 1 + (samples.count - n) / hop
        guard frames > 2 else { return [] }
        let log2n = vDSP_Length(log2(Double(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var frame = [Float](repeating: 0, count: n)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        var previous = [Float](repeating: 0, count: half)
        var flux = [Float](repeating: 0, count: frames)

        samples.withUnsafeBufferPointer { input in
            for i in 0..<frames {
                vDSP_vmul(input.baseAddress! + i * hop, 1, window, 1, &frame, 1, vDSP_Length(n))
                real.withUnsafeMutableBufferPointer { rp in
                    imag.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        frame.withUnsafeBufferPointer { fp in
                            fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                            }
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
                    }
                }
                // Log compression (zrip's output is twice the usual size).
                var total: Float = 0
                for b in 0..<half {
                    let m = log1p(50 * magnitudes[b])
                    if i > 0 { total += max(m - previous[b], 0) }
                    previous[b] = m
                }
                flux[i] = total
            }
        }

        // Subtract the local average (~0.4 s), keep only the rises, scale to 0…1.
        let fps = sampleRate / Double(hop)
        let width = max(Int(fps * 0.4) | 1, 3)
        let radius = width / 2
        var prefix = [Double](repeating: 0, count: frames + 1)
        for i in 0..<frames { prefix[i + 1] = prefix[i] + Double(flux[i]) }
        var env = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let lo = max(0, i - radius), hi = min(frames, i + radius + 1)
            let mean = (prefix[hi] - prefix[lo]) / Double(width)
            env[i] = max(flux[i] - Float(mean), 0)
        }
        let peak = env.max() ?? 0
        if peak > 0 {
            let scale = 1 / peak
            for i in env.indices { env[i] *= scale }
        }
        return env
    }

    /// Sum of the envelope at phase, phase + period, phase + 2·period …
    private static func comb(_ env: [Float], period: Double, phase: Double) -> Double {
        var sum = 0.0
        var t = phase
        let last = Double(env.count - 1)
        while t < last {
            let i = Int(t)
            let f = Float(t - Double(i))
            sum += Double(env[i] * (1 - f) + env[i + 1] * f)
            t += period
        }
        return sum
    }

    private static func interpolate(_ values: [Double], _ x: Double) -> Double {
        let i = Int(x)
        guard i >= 0, i + 1 < values.count else { return 0 }
        let f = x - Double(i)
        return values[i] * (1 - f) + values[i + 1] * f
    }
}
