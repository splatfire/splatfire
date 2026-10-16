import Foundation
import CoreGraphics

// Step 2 of the dance analysis: compare the tutorial poses with yours.
// Pure Swift math (no Vision, no video), so it is easy to test.
//
// How it works, in plain words:
//  1. Turn every pose into a few simple numbers ("features"): elbow angles,
//     knee angles, how high the hands are, and so on.
//  2. Try small time shifts (-0.6 s ... +0.6 s) and keep the one where your
//     poses match the tutorial best. That shift is your timing offset.
//  3. Cut the dance into 8-counts and score each one by how far your
//     features are from the tutorial's.

// MARK: - Joints

extension Joint {
    /// The same joint on the other side of the body (left <-> right).
    var swappedSide: Joint {
        switch self {
        case .nose, .neck, .root: return self
        case .leftShoulder: return .rightShoulder
        case .rightShoulder: return .leftShoulder
        case .leftElbow: return .rightElbow
        case .rightElbow: return .leftElbow
        case .leftWrist: return .rightWrist
        case .rightWrist: return .leftWrist
        case .leftHip: return .rightHip
        case .rightHip: return .leftHip
        case .leftKnee: return .rightKnee
        case .rightKnee: return .leftKnee
        case .leftAnkle: return .rightAnkle
        case .rightAnkle: return .leftAnkle
        }
    }
}

// MARK: - Features

/// One measurable thing about a pose. Angles are in degrees; hand height is
/// scaled to "degree-like" units so every feature counts about the same.
enum PoseFeature: Int, CaseIterable {
    case elbowLeft, elbowRight
    case shoulderLeft, shoulderRight   // how far the arm is raised from the torso
    case kneeLeft, kneeRight
    case hipLeft, hipRight             // torso vs thigh
    case torsoLean                     // signed: + = leaning to the right of the screen
    case wristLeft, wristRight         // hand height relative to the shoulder
}

/// All features of one pose at one time. A missing feature is `.nan`.
struct PoseFrame {
    var time: Double
    /// Indexed by `PoseFeature.rawValue`.
    var values: [Double]

    /// One torso length of hand height counts as this many "degrees".
    static let handHeightScale = 50.0

    /// Computes the features of `sample`.
    /// - Parameter mirrored: the video is shown mirrored, so flip the pose the
    ///   same way (x -> 1 - x and swap left/right) and compare what you SEE.
    static func make(from sample: PoseSample, mirrored: Bool) -> PoseFrame {
        // Joint positions: aspect-corrected so angles are not squashed.
        var pts: [Joint: Vec2] = [:]
        for (joint, p) in sample.joints {
            let x = (mirrored ? 1 - Double(p.x) : Double(p.x)) * sample.aspect
            pts[mirrored ? joint.swappedSide : joint] = Vec2(x: x, y: Double(p.y))
        }

        var v = [Double](repeating: .nan, count: PoseFeature.allCases.count)

        // The torso line (neck -> root), with fallbacks if a joint is missing.
        let neck = pts[.neck] ?? midpoint(pts[.leftShoulder], pts[.rightShoulder])
        let root = pts[.root] ?? midpoint(pts[.leftHip], pts[.rightHip])
        var torsoDown: Vec2?
        var torsoLength = 0.0
        if let n = neck, let r = root {
            let down = r - n
            if down.length > 0.05 {
                torsoDown = down
                torsoLength = down.length
                // Angle of the torso against straight up (screen right = +).
                let up = n - r
                v[PoseFeature.torsoLean.rawValue] = atan2(up.x, -up.y) * 180 / Double.pi
            }
        }

        for s in sideSpecs {
            let shoulder = pts[s.shoulder]
            let elbow = pts[s.elbow]
            let wrist = pts[s.wrist]
            if let sh = shoulder, let el = elbow, let wr = wrist {
                v[s.elbowFeature.rawValue] = angleDegrees(sh - el, wr - el)
            }
            if let sh = shoulder, let el = elbow, let down = torsoDown {
                v[s.shoulderFeature.rawValue] = angleDegrees(down, el - sh)
            }
            if let sh = shoulder, let wr = wrist, torsoLength > 0 {
                // y grows downward, so (shoulder - wrist) > 0 = hand above shoulder.
                v[s.wristFeature.rawValue] = (sh.y - wr.y) / torsoLength * handHeightScale
            }
            if let hip = pts[s.hip], let knee = pts[s.knee], let ankle = pts[s.ankle] {
                v[s.kneeFeature.rawValue] = angleDegrees(hip - knee, ankle - knee)
            }
            if let n = neck, let hip = pts[s.hip], let knee = pts[s.knee] {
                v[s.hipFeature.rawValue] = angleDegrees(n - hip, knee - hip)
            }
        }
        return PoseFrame(time: sample.time, values: v)
    }

    private struct SideSpec {
        let shoulder: Joint, elbow: Joint, wrist: Joint
        let hip: Joint, knee: Joint, ankle: Joint
        let elbowFeature: PoseFeature, shoulderFeature: PoseFeature
        let kneeFeature: PoseFeature, hipFeature: PoseFeature, wristFeature: PoseFeature
    }

    private static let sideSpecs: [SideSpec] = [
        SideSpec(shoulder: .leftShoulder, elbow: .leftElbow, wrist: .leftWrist,
                 hip: .leftHip, knee: .leftKnee, ankle: .leftAnkle,
                 elbowFeature: .elbowLeft, shoulderFeature: .shoulderLeft,
                 kneeFeature: .kneeLeft, hipFeature: .hipLeft, wristFeature: .wristLeft),
        SideSpec(shoulder: .rightShoulder, elbow: .rightElbow, wrist: .rightWrist,
                 hip: .rightHip, knee: .rightKnee, ankle: .rightAnkle,
                 elbowFeature: .elbowRight, shoulderFeature: .shoulderRight,
                 kneeFeature: .kneeRight, hipFeature: .hipRight, wristFeature: .wristRight),
    ]

    private static func midpoint(_ a: Vec2?, _ b: Vec2?) -> Vec2? {
        guard let a, let b else { return nil }
        return Vec2(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    /// Angle in degrees (0...180) between two vectors; `.nan` if one is tiny.
    private static func angleDegrees(_ u: Vec2, _ w: Vec2) -> Double {
        let lu = u.length, lw = w.length
        guard lu > 1e-4, lw > 1e-4 else { return .nan }
        let cosine = max(-1.0, min(1.0, (u.x * w.x + u.y * w.y) / (lu * lw)))
        return acos(cosine) * 180 / Double.pi
    }
}

/// A tiny 2D vector (so we don't juggle CGFloat/Double conversions).
struct Vec2 {
    var x: Double
    var y: Double
    var length: Double { (x * x + y * y).squareRoot() }
    static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x - b.x, y: a.y - b.y) }
}

// MARK: - Errors

enum PoseComparerError: LocalizedError {
    /// The tutorial dancer could not be found.
    case tutorialNotFound
    /// You could not be seen well enough.
    case bodyNotFound

    var errorDescription: String? {
        switch self {
        case .tutorialNotFound:
            return "I couldn't find the dancer in the tutorial video. Try a section where the dancer's whole body is visible."
        case .bodyNotFound:
            return "I couldn't see your whole body clearly. Make sure your whole body is in the camera view, the room is bright, and only you are in the frame."
        }
    }
}

// MARK: - Comparer

enum PoseComparer {
    /// Everything the comparison needs (plain values, safe to use anywhere).
    struct Input: Sendable {
        /// Poses found in the tutorial (frames without a person are missing).
        var tutorial: [PoseSample]
        /// Poses found in the take, including a margin for the lag search.
        var take: [PoseSample]
        /// How many tutorial frames were looked at in total (found or not).
        var plannedTutorialFrames: Int
        var timing: TakeTiming
        /// Tutorial time range that the take covers.
        var tutorialRange: ClosedRange<Double>
        var tutorialDuration: Double
        /// Song tempo (0 = not set) and where count 1 starts.
        var bpm: Double
        var offset: Double
        var tutorialMirrored: Bool
        var takeMirrored: Bool
    }

    // Tuning numbers.
    static let lagStep = 0.1
    static let maxLagSteps = 6                 // -0.6 ... +0.6 s
    static let minCoverage = 0.3
    static let findingThreshold = 12.0         // degrees
    static let minSegmentSeconds = 1.0
    static let chunkSeconds = 4.0
    static let lateThreshold = 0.15            // seconds, for a timing tip
    static let sizeRatioThreshold = 0.7

    /// Compares the take with the tutorial and returns a report
    /// (`coachText` / `coachSource` are left empty for `CoachWriter`).
    static func compare(_ input: Input, now: Date = Date()) throws -> AnalysisReport {
        let planned = max(input.plannedTutorialFrames, 1)
        guard Double(input.tutorial.count) / Double(planned) >= minCoverage else {
            throw PoseComparerError.tutorialNotFound
        }
        guard !input.take.isEmpty else { throw PoseComparerError.bodyNotFound }

        let tut = input.tutorial.sorted { $0.time < $1.time }
            .map { PoseFrame.make(from: $0, mirrored: input.tutorialMirrored) }
        let take = input.take.sorted { $0.time < $1.time }
            .map { PoseFrame.make(from: $0, mirrored: input.takeMirrored) }
        let n = tut.count
        let takeTimes = take.map { $0.time }
        // How far (in take seconds) a sample may be from the wanted moment.
        let tolerance = max(0.12, medianSpacing(takeTimes) * 1.2)

        // For every lag and every tutorial frame: how different is the pose?
        let lagCount = 2 * maxLagSteps + 1
        var diffs = [[Double]](repeating: [Double](repeating: .nan, count: n), count: lagCount)
        var matched = [[Int]](repeating: [Int](repeating: -1, count: n), count: lagCount)
        for li in 0..<lagCount {
            let lag = Double(li - maxLagSteps) * lagStep
            for i in 0..<n {
                // Lag is in tutorial seconds: look at your pose at (t + lag).
                let target = input.timing.takeTime(forTutorialTime: tut[i].time + lag)
                guard let j = nearestIndex(takeTimes, to: target),
                      abs(takeTimes[j] - target) <= tolerance else { continue }
                let d = difference(tut[i].values, take[j].values)
                if d.isNaN { continue }
                diffs[li][i] = d
                matched[li][i] = j
            }
        }

        // Best overall lag. If you are LATE by d, your pose at (t + d) equals
        // the tutorial pose at t, so best lag = +d (+ = late).
        guard let globalLag = chooseLagIndex(diffs: diffs, range: 0..<n, minCount: 5) else {
            throw PoseComparerError.bodyNotFound
        }
        let global = meanDiff(diffs[globalLag], 0..<n)
        let coverage = min(1, Double(global.count) / Double(planned))
        guard coverage >= minCoverage else { throw PoseComparerError.bodyNotFound }
        let globalOffset = Double(globalLag - maxLagSteps) * lagStep

        // 8-counts (or time chunks without a BPM).
        let rangeStart = input.tutorialRange.lowerBound
        let rangeEnd = input.tutorialRange.upperBound
        var grid: CountGrid?
        if input.bpm > 0 {
            let candidate = CountGrid(bpm: input.bpm, offset: input.offset, duration: input.tutorialDuration)
            if candidate.isValid { grid = candidate }
        }
        let specs = segmentSpecs(rangeStart: rangeStart, rangeEnd: rangeEnd, grid: grid)
        let ctx = Context(tut: tut, take: take, diffs: diffs, matched: matched,
                          globalLag: globalLag, takeMirrored: input.takeMirrored, grid: grid)

        var segments: [AnalysisReport.SegmentResult] = []
        for spec in specs {
            let isLast = spec.end >= rangeEnd - 1e-6
            let range = indexRange(tut, start: spec.start, end: spec.end, inclusiveEnd: isLast)
            if range.isEmpty { continue }
            if let result = analyzeSegment(spec: spec, range: range, ctx: ctx) {
                segments.append(result)
            }
        }

        // Overall score = average of the segments, longer ones count more.
        let overall: Int
        if segments.isEmpty {
            overall = score(forMeanDifference: global.mean)
        } else {
            var weighted = 0.0, total = 0.0
            for s in segments {
                let w = max(s.end - s.start, 0.1)
                weighted += Double(s.score) * w
                total += w
            }
            overall = max(0, min(100, Int((weighted / total).rounded())))
        }

        // The most important findings: biggest first, one per body part.
        let allFindings = segments.flatMap { $0.findings }
            .sorted { a, b in a.severity != b.severity ? a.severity > b.severity : a.time < b.time }
        var seen = Set<String>()
        var top: [AnalysisReport.Finding] = []
        for f in allFindings where !seen.contains(f.bodyPart) {
            seen.insert(f.bodyPart)
            top.append(f)
            if top.count == 5 { break }
        }

        return AnalysisReport(
            createdAt: now,
            overallScore: overall,
            timingOffset: globalOffset,
            poseCoverage: coverage,
            segments: segments,
            topFindings: top,
            coachText: "",
            coachSource: "",
            tutorialMirrored: input.tutorialMirrored,
            takeMirrored: input.takeMirrored
        )
    }

    // MARK: Scoring helpers

    /// 100 minus 1.6 points per degree of average difference.
    static func score(forMeanDifference mean: Double) -> Int {
        guard mean.isFinite else { return 0 }
        return max(0, min(100, Int(100 - mean * 1.6)))
    }

    /// Average absolute difference over the features both poses have, or
    /// `.nan` when fewer than 3 features can be compared.
    static func difference(_ a: [Double], _ b: [Double]) -> Double {
        var sum = 0.0
        var count = 0
        for i in 0..<min(a.count, b.count) {
            let x = a[i], y = b[i]
            if x.isNaN || y.isNaN { continue }
            sum += abs(x - y)
            count += 1
        }
        return count >= 3 ? sum / Double(count) : .nan
    }

    /// Index of the sample whose time is closest to `t` (`times` is sorted).
    static func nearestIndex(_ times: [Double], to t: Double) -> Int? {
        guard !times.isEmpty else { return nil }
        var lo = 0, hi = times.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        // `lo` is the first sample at or after t; the one before may be closer.
        if lo > 0, abs(times[lo - 1] - t) <= abs(times[lo] - t) { return lo - 1 }
        return lo
    }

    /// Typical gap between samples (robust against a few missing frames).
    private static func medianSpacing(_ times: [Double]) -> Double {
        guard times.count > 1 else { return 0.1 }
        var gaps: [Double] = []
        for i in 1..<times.count { gaps.append(times[i] - times[i - 1]) }
        gaps.sort()
        return gaps[gaps.count / 2]
    }

    /// Mean of the non-missing differences in `range`.
    private static func meanDiff(_ row: [Double], _ range: Range<Int>) -> (mean: Double, count: Int) {
        var sum = 0.0
        var count = 0
        for i in range where !row[i].isNaN {
            sum += row[i]
            count += 1
        }
        return (count > 0 ? sum / Double(count) : .nan, count)
    }

    /// Lags are tried 0, -1, +1, -2, +2 ... so that on a tie the smaller one wins.
    private static var lagOrder: [Int] {
        var order = [0]
        for k in 1...maxLagSteps {
            order.append(-k)
            order.append(k)
        }
        return order
    }

    /// The lag (as an index into `diffs`) with the smallest mean difference.
    private static func bestLagIndex(diffs: [[Double]], range: Range<Int>, minCount: Int) -> Int? {
        var best: (index: Int, mean: Double)?
        for k in lagOrder {
            let li = k + maxLagSteps
            let stats = meanDiff(diffs[li], range)
            guard stats.count >= minCount else { continue }
            if let b = best, stats.mean >= b.mean - 1e-9 { continue }
            best = (li, stats.mean)
        }
        return best?.index
    }

    /// Like `bestLagIndex`, but only leaves "no shift" when it clearly helps.
    private static func chooseLagIndex(diffs: [[Double]], range: Range<Int>, minCount: Int) -> Int? {
        guard let best = bestLagIndex(diffs: diffs, range: range, minCount: minCount) else { return nil }
        let zero = maxLagSteps
        if best == zero { return best }
        let z = meanDiff(diffs[zero], range)
        let b = meanDiff(diffs[best], range)
        if z.count >= minCount, z.mean - b.mean < max(0.5, 0.03 * z.mean) { return zero }
        return best
    }

    // MARK: Segments

    private struct SegmentSpec {
        let index: Int
        let isEight: Bool
        let start: Double
        let end: Double
    }

    private struct Context {
        let tut: [PoseFrame]
        let take: [PoseFrame]
        let diffs: [[Double]]
        let matched: [[Int]]
        let globalLag: Int
        let takeMirrored: Bool
        let grid: CountGrid?
    }

    /// 8-counts overlapping the take, or 4-second chunks without a BPM.
    private static func segmentSpecs(rangeStart: Double, rangeEnd: Double, grid: CountGrid?) -> [SegmentSpec] {
        if let grid, grid.numberOfEightCounts > 0 {
            var specs: [SegmentSpec] = []
            let first = max(0, Int(((rangeStart - grid.offset) / grid.eightCountDuration).rounded(.down)))
            var i = first
            while i < grid.numberOfEightCounts {
                if grid.start(of: i) >= rangeEnd { break }
                // Only the part inside the take counts.
                let s = max(grid.start(of: i), rangeStart)
                let e = min(grid.end(of: i), rangeEnd)
                if e - s >= minSegmentSeconds {
                    specs.append(SegmentSpec(index: i, isEight: true, start: s, end: e))
                }
                i += 1
            }
            if !specs.isEmpty { return specs }
        }

        var specs: [SegmentSpec] = []
        var start = rangeStart
        var index = 0
        while start < rangeEnd - 1e-6 {
            var end = min(start + chunkSeconds, rangeEnd)
            // Don't leave a tiny leftover chunk at the end.
            if rangeEnd - end < 1.5 { end = rangeEnd }
            specs.append(SegmentSpec(index: index, isEight: false, start: start, end: end))
            start = end
            index += 1
        }
        return specs
    }

    /// The tutorial frames (as an index range) between `start` and `end`.
    private static func indexRange(_ frames: [PoseFrame], start: Double, end: Double, inclusiveEnd: Bool) -> Range<Int> {
        var lo = frames.count
        var hi = 0
        for (i, f) in frames.enumerated() {
            let afterStart = f.time >= start - 1e-6
            let beforeEnd = inclusiveEnd ? f.time <= end + 1e-6 : f.time < end - 1e-6
            if afterStart && beforeEnd {
                lo = min(lo, i)
                hi = max(hi, i + 1)
            }
        }
        return lo < hi ? lo..<hi : 0..<0
    }

    // MARK: Findings

    private enum GroupKind { case elbow, shoulder, hand, knees, hips, lean }
    private enum PoseSide { case left, right
        var opposite: PoseSide { self == .left ? .right : .left }
    }

    /// Features that are described together in one tip.
    private struct FeatureGroup {
        let kind: GroupKind
        let side: PoseSide?
        let features: [PoseFeature]
        /// Groups with the same key are alternatives (only the bigger is reported).
        let exclusive: String
    }

    private static let featureGroups: [FeatureGroup] = [
        FeatureGroup(kind: .elbow, side: .left, features: [.elbowLeft], exclusive: "elbow-left"),
        FeatureGroup(kind: .elbow, side: .right, features: [.elbowRight], exclusive: "elbow-right"),
        FeatureGroup(kind: .shoulder, side: .left, features: [.shoulderLeft], exclusive: "arm-left"),
        FeatureGroup(kind: .shoulder, side: .right, features: [.shoulderRight], exclusive: "arm-right"),
        FeatureGroup(kind: .hand, side: .left, features: [.wristLeft], exclusive: "arm-left"),
        FeatureGroup(kind: .hand, side: .right, features: [.wristRight], exclusive: "arm-right"),
        FeatureGroup(kind: .knees, side: nil, features: [.kneeLeft, .kneeRight], exclusive: "knees"),
        FeatureGroup(kind: .hips, side: nil, features: [.hipLeft, .hipRight], exclusive: "hips"),
        FeatureGroup(kind: .lean, side: nil, features: [.torsoLean], exclusive: "lean"),
    ]

    private struct Candidate {
        let order: Int
        let group: FeatureGroup
        /// Average (your value - tutorial value) in the segment.
        let mean: Double
        /// Tutorial time where the difference is biggest.
        let time: Double
    }

    /// Scores one 8-count (or chunk) and finds what to work on.
    private static func analyzeSegment(spec: SegmentSpec, range: Range<Int>, ctx: Context) -> AnalysisReport.SegmentResult? {
        let globalRow = ctx.diffs[ctx.globalLag]
        let stats = meanDiff(globalRow, range)
        guard stats.count >= 3 else { return nil }
        let segmentScore = score(forMeanDifference: stats.mean)

        // Local timing in this segment.
        let localLag = chooseLagIndex(diffs: ctx.diffs, range: range, minCount: 4) ?? ctx.globalLag
        let lag = Double(localLag - maxLagSteps) * lagStep

        // 1. Joint-angle differences, direction included.
        var candidates: [Candidate] = []
        for (order, group) in featureGroups.enumerated() {
            var perFrame: [(time: Double, value: Double)] = []
            for i in range {
                let j = ctx.matched[ctx.globalLag][i]
                if j < 0 { continue }
                var sum = 0.0
                var count = 0
                for f in group.features {
                    let mine = ctx.take[j].values[f.rawValue]
                    let theirs = ctx.tut[i].values[f.rawValue]
                    if mine.isNaN || theirs.isNaN { continue }
                    sum += mine - theirs
                    count += 1
                }
                if count > 0 { perFrame.append((ctx.tut[i].time, sum / Double(count))) }
            }
            guard perFrame.count >= 4 else { continue }
            let mean = perFrame.reduce(0.0) { $0 + $1.value } / Double(perFrame.count)
            guard abs(mean) >= findingThreshold else { continue }
            let sign: Double = mean >= 0 ? 1 : -1
            let peak = perFrame.max { $0.value * sign < $1.value * sign }
            candidates.append(Candidate(order: order, group: group, mean: mean, time: peak?.time ?? perFrame[0].time))
        }
        candidates.sort { a, b in
            abs(a.mean) != abs(b.mean) ? abs(a.mean) > abs(b.mean) : a.order < b.order
        }

        var findings: [AnalysisReport.Finding] = []
        var usedKeys = Set<String>()
        for c in candidates {
            if usedKeys.contains(c.group.exclusive) { continue }
            usedKeys.insert(c.group.exclusive)
            let text = describe(c.group, userIsBigger: c.mean > 0, takeMirrored: ctx.takeMirrored)
            findings.append(makeFinding(bodyPart: text.bodyPart, message: text.message,
                                        severity: abs(c.mean), time: c.time, spec: spec, grid: ctx.grid))
            if findings.count == 3 { break }
        }

        // 2. Range of motion: are your moves as big as the tutorial's?
        var sumTutorial = 0.0, sumUser = 0.0
        var moving = 0
        for f in PoseFeature.allCases {
            var theirs: [Double] = []
            var mine: [Double] = []
            for i in range {
                let j = ctx.matched[ctx.globalLag][i]
                if j < 0 { continue }
                let a = ctx.tut[i].values[f.rawValue]
                let b = ctx.take[j].values[f.rawValue]
                if a.isNaN || b.isNaN { continue }
                theirs.append(a)
                mine.append(b)
            }
            guard theirs.count >= 6 else { continue }
            let spread = standardDeviation(theirs)
            guard spread >= 6 else { continue }   // this joint barely moves in the tutorial
            sumTutorial += spread
            sumUser += standardDeviation(mine)
            moving += 1
        }
        if moving >= 2 {
            let ratio = sumUser / sumTutorial
            if ratio < sizeRatioThreshold {
                findings.append(makeFinding(bodyPart: "Move size", message: "Make your moves bigger and sharper",
                                            severity: (1 - ratio) * 60, time: spec.start, spec: spec, grid: ctx.grid))
            }
            // 3. Timing (only meaningful when the tutorial dancer is really moving).
            if abs(lag) >= lateThreshold {
                let amount = String(format: "%.1f", abs(lag))
                let message = lag > 0
                    ? "You're about \(amount) s late here — hit the beat earlier"
                    : "You're about \(amount) s early here — let the beat arrive before you move"
                findings.append(makeFinding(bodyPart: "Timing", message: message,
                                            severity: abs(lag) * 100, time: spec.start, spec: spec, grid: ctx.grid))
            }
        }

        findings.sort { a, b in a.severity != b.severity ? a.severity > b.severity : a.time < b.time }

        return AnalysisReport.SegmentResult(
            index: spec.index,
            isEightCount: spec.isEight,
            start: spec.start,
            end: spec.end,
            score: segmentScore,
            timingOffset: lag,
            findings: findings
        )
    }

    private static func makeFinding(bodyPart: String, message: String, severity: Double,
                                    time: Double, spec: SegmentSpec, grid: CountGrid?) -> AnalysisReport.Finding {
        var eightCount: Int?
        var beat: Int?
        if spec.isEight, let grid {
            eightCount = spec.index
            beat = grid.beat(at: time)
        }
        return AnalysisReport.Finding(bodyPart: bodyPart, message: message, severity: severity,
                                      time: time, eightCount: eightCount, beat: beat)
    }

    private static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance.squareRoot()
    }

    // MARK: Plain-English tips

    /// "left"/"right" as the USER means it (their own body).
    /// Poses are labeled by how they look on screen; a mirrored take shows
    /// your left arm on the screen's left, so its labels must be swapped back.
    private static func sideWord(_ label: PoseSide, takeMirrored: Bool) -> String {
        let anatomical = takeMirrored ? label.opposite : label
        return anatomical == .left ? "left" : "right"
    }

    /// Body part name and instruction. `userIsBigger` = your value is larger
    /// than the tutorial's (more straight, higher, ...).
    private static func describe(_ group: FeatureGroup, userIsBigger: Bool, takeMirrored: Bool) -> (bodyPart: String, message: String) {
        let w = group.side.map { sideWord($0, takeMirrored: takeMirrored) } ?? ""
        let cap = w.capitalized
        switch group.kind {
        case .elbow:
            return ("\(cap) elbow",
                    userIsBigger ? "Bend your \(w) elbow more" : "Straighten your \(w) arm more")
        case .shoulder:
            return ("\(cap) arm",
                    userIsBigger ? "Keep your \(w) arm lower" : "Lift your \(w) arm higher")
        case .hand:
            return ("\(cap) hand",
                    userIsBigger ? "Bring your \(w) hand lower" : "Raise your \(w) hand higher")
        case .knees:
            return ("Knees",
                    userIsBigger ? "Bend your knees more — get lower" : "Stand a bit taller")
        case .hips:
            return ("Hips",
                    userIsBigger ? "Hinge forward a bit more at your hips" : "Open your hips — stand more upright")
        case .lean:
            // Bigger = leaning more to the right of the screen, so ask for the other way.
            let side = (userIsBigger == takeMirrored) ? "left" : "right"
            return ("Torso", "Lean your upper body a bit more to your \(side)")
        }
    }
}

// MARK: - Small shared helpers for the report

/// "1:05" style time.
func analysisClock(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0:00" }
    let total = Int(max(0, seconds).rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}

extension AnalysisReport.Finding {
    /// "8-count 3 · count 5" (8-counts are shown from 1), or the time.
    var whereText: String {
        if let eightCount, let beat { return "8-count \(eightCount + 1) · count \(beat)" }
        if let eightCount { return "8-count \(eightCount + 1)" }
        return "at \(analysisClock(time))"
    }
}

extension AnalysisReport.SegmentResult {
    /// "8-count 3" or "0:08 – 0:12".
    var label: String {
        isEightCount ? "8-count \(index + 1)" : "\(analysisClock(start)) – \(analysisClock(end))"
    }
}

extension AnalysisReport {
    /// One friendly sentence about timing.
    var timingHeadline: String {
        if abs(timingOffset) < 0.08 { return "On the beat 👍" }
        let amount = String(format: "%.2f", abs(timingOffset))
        if timingOffset > 0 {
            return "About \(amount) s late — try to hit each count a little earlier"
        }
        return "About \(amount) s early — try to wait for each count a little"
    }
}
