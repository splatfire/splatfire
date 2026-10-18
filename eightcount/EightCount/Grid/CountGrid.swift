import Foundation

/// Pure math that splits a video into 8-counts.
///
///     offset          offset + 1 × eightCountDuration
///     |-- 8-count 1 --|-- 8-count 2 --|-- ...
///
/// Indexes are 0-based in code and shown 1-based on screen.
struct CountGrid: Equatable {
    var bpm: Double
    /// Video time (seconds) where count 1 of the first 8-count starts.
    var offset: Double
    /// Video length in seconds.
    var duration: Double

    /// False until a BPM has been set (and the video length is known).
    var isValid: Bool { bpm > 0 && duration > 0 && bpm.isFinite }

    /// Length of one beat ("one count") in seconds.
    var beatDuration: Double { 60.0 / bpm }

    /// Length of one 8-count in seconds.
    var eightCountDuration: Double { beatDuration * 8 }

    /// How many 8-counts fit between `offset` and the end of the video.
    /// A partial 8-count at the end still counts.
    var numberOfEightCounts: Int {
        guard isValid, duration.isFinite, offset < duration else { return 0 }
        // Tiny epsilon so floating-point noise doesn't add an empty 8-count.
        let count = ceil((duration - offset) / eightCountDuration - 1e-9)
        // Never turn a huge number into an Int (that would crash the app).
        return count < 1_000_000 ? Int(count) : 1_000_000
    }

    /// A grid for when the video length doesn't matter (e.g. just to know
    /// which 8-count a time is in): long enough for any dance (24 hours).
    static func unbounded(bpm: Double, offset: Double) -> CountGrid {
        CountGrid(bpm: bpm, offset: offset, duration: 24 * 3600)
    }

    /// Start time of 8-count `index`.
    func start(of index: Int) -> Double {
        offset + Double(index) * eightCountDuration
    }

    /// End time of 8-count `index` (clamped to the video length).
    func end(of index: Int) -> Double {
        min(start(of: index + 1), duration)
    }

    /// A tiny tolerance (0.1 ms). After jumping to the start of an 8-count,
    /// rounding in the math and in the video's time stamps can leave the
    /// playhead a hair *before* the start; this still counts it as the new one.
    private static let boundaryTolerance = 0.0001

    /// The 8-count playing at `time`, or nil before count 1 / without BPM.
    func index(at time: Double) -> Int? {
        let count = numberOfEightCounts
        let t = time + Self.boundaryTolerance
        // No 8-counts at all (e.g. count 1 is after the end of the video).
        guard isValid, count > 0, time.isFinite, t >= offset else { return nil }
        let i = Int(floor((t - offset) / eightCountDuration))
        return min(i, count - 1)
    }

    /// The count (1...8) within its 8-count at `time`, or nil before count 1.
    func beat(at time: Double) -> Int? {
        let t = time + Self.boundaryTolerance
        guard isValid, time.isFinite, t >= offset else { return nil }
        let intoEight = (t - offset).truncatingRemainder(dividingBy: eightCountDuration)
        return min(Int(floor(intoEight / beatDuration)) + 1, 8)
    }
}
