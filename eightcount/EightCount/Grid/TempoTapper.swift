import Foundation
import QuartzCore

/// Works out a tempo (BPM) from you tapping along with the beat.
///
/// Pure logic, no UI: call `tap()` on every beat, read `bpm`.
/// If you stop for a while (more than `resetInterval` seconds), the next tap
/// starts a fresh measurement.
struct TempoTapper {
    /// How many taps since the last reset.
    private(set) var tapCount: Int = 0

    /// A pause longer than this (seconds) starts over. Default 2 s.
    var resetInterval: TimeInterval

    /// Only the most recent intervals are averaged, so the result follows
    /// you if you speed up or slow down a little.
    static let maxIntervals = 8

    private var lastTapTime: TimeInterval?
    private var intervals: [TimeInterval] = []

    init(resetInterval: TimeInterval = 2) {
        self.resetInterval = resetInterval
    }

    /// Beats per minute from your taps, or nil until you have tapped twice.
    var bpm: Double? {
        guard !intervals.isEmpty else { return nil }
        let average = intervals.reduce(0, +) / Double(intervals.count)
        guard average > 0 else { return nil }
        return 60.0 / average
    }

    /// Call this on every beat. `time` is in seconds (any clock that only
    /// moves forward; the default is the system's media clock).
    mutating func tap(at time: TimeInterval = CACurrentMediaTime()) {
        if let last = lastTapTime {
            let gap = time - last
            if gap <= 0 {
                // Two taps at the same instant (or a clock glitch): ignore.
                return
            }
            if gap > resetInterval {
                // Long pause: start a new measurement with this tap.
                reset()
            } else {
                intervals.append(gap)
                if intervals.count > Self.maxIntervals {
                    intervals.removeFirst(intervals.count - Self.maxIntervals)
                }
            }
        }
        lastTapTime = time
        tapCount += 1
    }

    /// Forget all taps.
    mutating func reset() {
        tapCount = 0
        lastTapTime = nil
        intervals.removeAll()
    }

    // MARK: - Small BPM helpers shared by the tempo screens

    /// The allowed BPM range in the app.
    static let validRange: ClosedRange<Double> = 40...250

    /// Rounds to 1 decimal, e.g. 119.96 → 120.0, 92.44 → 92.4.
    static func rounded(_ bpm: Double) -> Double {
        (bpm * 10).rounded() / 10
    }

    /// "120" for whole numbers, "92.5" otherwise.
    static func displayString(for bpm: Double) -> String {
        guard bpm.isFinite else { return "–" }
        let value = rounded(bpm)
        if value == value.rounded() {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}
