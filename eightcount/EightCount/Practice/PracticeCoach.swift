import Foundation
import Observation

/// Runs a practice plan on the looping player, one step at a time:
///
/// - **Build up**: 8-count 1, then 1–2, then 1–3 … until the whole part,
///   each step a few times. (The "add-on" way dance teachers teach.)
/// - **Speed ladder**: the same part at 0.5×, then 0.75×, then 1×.
///
/// A step moves on by itself after its runs: the player's loop counter
/// (`loopWraps`) goes up each time the loop jumps back to its start.
@MainActor
@Observable
final class PracticeCoach {
    enum Kind: Equatable {
        case buildUp
        case speedLadder
    }

    struct Step: Equatable {
        var first: Int
        var last: Int
        var rate: Float
        var runs: Int
    }

    private(set) var kind: Kind?
    private(set) var steps: [Step] = []
    private(set) var stepIndex = 0
    private(set) var runsDone = 0
    /// True after the last step: the whole part keeps looping at full plan speed.
    private(set) var isFinished = false
    /// A name for what's being drilled ("Chorus"), if it came from a section.
    private(set) var partName: String?

    @ObservationIgnored private var wrapsAtStepStart = 0

    var isActive: Bool { kind != nil }
    var step: Step? { steps.indices.contains(stepIndex) ? steps[stepIndex] : nil }

    // MARK: - Plans

    /// 8-count `first`, then `first…first+1`, … up to `last`.
    func startBuildUp(first: Int, last: Int, runs: Int, rate: Float, name: String?,
                      controller: PlayerController, grid: CountGrid) {
        let last = max(first, last)
        let plan = (first...last).map { Step(first: first, last: $0, rate: rate, runs: runs) }
        begin(.buildUp, plan, name: name, controller: controller, grid: grid)
    }

    /// `first…last` at 0.5×, 0.75×, then 1×.
    func startSpeedLadder(first: Int, last: Int, runs: Int, name: String?,
                          controller: PlayerController, grid: CountGrid) {
        let plan = Self.ladderSpeeds.map { Step(first: first, last: max(first, last), rate: $0, runs: runs) }
        begin(.speedLadder, plan, name: name, controller: controller, grid: grid)
    }

    static let ladderSpeeds: [Float] = [0.5, 0.75, 1.0]

    // MARK: - Running

    /// Call whenever `controller.loopWraps` changes.
    func loopWrapped(controller: PlayerController, grid: CountGrid) {
        guard isActive, !isFinished, let step else { return }
        runsDone = controller.loopWraps - wrapsAtStepStart
        guard runsDone >= step.runs else { return }
        if stepIndex + 1 < steps.count {
            stepIndex += 1
            apply(controller: controller, grid: grid)
        } else {
            // Done: keep looping the whole part so you can run it full out.
            isFinished = true
        }
    }

    /// Skip ahead to the next step (or finish).
    func next(controller: PlayerController, grid: CountGrid) {
        guard isActive else { return }
        if stepIndex + 1 < steps.count {
            stepIndex += 1
            isFinished = false
            apply(controller: controller, grid: grid)
        } else {
            isFinished = true
        }
    }

    /// Start the plan over.
    func restart(controller: PlayerController, grid: CountGrid) {
        guard isActive else { return }
        stepIndex = 0
        isFinished = false
        apply(controller: controller, grid: grid)
    }

    /// Ends the plan. The loop stays as it is.
    func stop() {
        kind = nil
        steps = []
        stepIndex = 0
        runsDone = 0
        isFinished = false
        partName = nil
    }

    // MARK: - Text for the screen

    var title: String {
        switch kind {
        case .buildUp: return "Build up"
        case .speedLadder: return "Speed ladder"
        case nil: return ""
        }
    }

    var stepText: String {
        guard let step else { return "" }
        if isFinished {
            return kind == .buildUp ? "You've got it all – run the whole thing!" : "Full speed – keep going!"
        }
        let range = step.first == step.last ? "8-count \(step.first + 1)" : "8-counts \(step.first + 1)–\(step.last + 1)"
        let speed = kind == .speedLadder ? " at \(Self.speedText(step.rate))" : ""
        return "\(range)\(speed) · run \(min(runsDone + 1, step.runs)) of \(step.runs)"
    }

    static func speedText(_ rate: Float) -> String {
        switch rate {
        case 0.25: return "¼×"
        case 0.5: return "½×"
        case 0.75: return "¾×"
        default: return rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%.2g×", rate)
        }
    }

    // MARK: - Private

    private func begin(_ kind: Kind, _ plan: [Step], name: String?, controller: PlayerController, grid: CountGrid) {
        guard grid.isValid, !plan.isEmpty else { return }
        self.kind = kind
        steps = plan
        stepIndex = 0
        isFinished = false
        partName = name
        apply(controller: controller, grid: grid)
        if !controller.isPlaying { controller.play() }
    }

    private func apply(controller: PlayerController, grid: CountGrid) {
        guard let step else { return }
        runsDone = 0
        wrapsAtStepStart = controller.loopWraps
        if controller.rate != step.rate { controller.setRate(step.rate) }
        let start = max(grid.start(of: step.first), 0)
        let end = grid.end(of: step.last)
        if step.first == step.last {
            controller.loopEightCount(step.first, start: start, end: end)
        } else {
            controller.loopSpan(start: start, end: end)
        }
    }
}
