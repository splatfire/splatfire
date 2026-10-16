import Foundation

/// Pure math that lines up a recording of you ("take") with the tutorial.
///
/// Everything in the compare screen is measured in *tutorial time*. For a
/// tutorial time `t`, your take shows the moment
///
///     takeOffset + (t - tutorialStart) / recordRate + syncNudge
///
/// (if you recorded at 0.5× speed, one tutorial second = two take seconds).
struct TakeTiming: Equatable, Sendable {
    var tutorialStart: Double
    var tutorialEnd: Double
    var takeOffset: Double
    var recordRate: Double
    var syncNudge: Double

    /// Safe rate (never 0).
    var rate: Double { recordRate > 0 ? recordRate : 1 }

    /// Tutorial range covered by the take.
    var tutorialRange: ClosedRange<Double> {
        tutorialStart...max(tutorialEnd, tutorialStart)
    }

    /// Take time that matches tutorial time `t`.
    func takeTime(forTutorialTime t: Double) -> Double {
        takeOffset + (t - tutorialStart) / rate + syncNudge
    }

    /// Tutorial time that matches take time `s`.
    func tutorialTime(forTakeTime s: Double) -> Double {
        tutorialStart + (s - takeOffset - syncNudge) * rate
    }

    /// Playback speed for the take when the tutorial plays at `tutorialRate`.
    func takeRate(forTutorialRate tutorialRate: Double) -> Double {
        tutorialRate / rate
    }
}
