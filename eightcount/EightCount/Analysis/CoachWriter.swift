import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// Step 3 of the dance analysis: turn the numbers into friendly tips.
// Uses Apple Intelligence (the on-device language model) when it is
// available. Otherwise (older iPhone, older iOS, model not ready, any error)
// it writes simple tips with plain rules. Nothing leaves the phone.

enum CoachWriter {
    /// Source label for text written by the on-device model.
    static let appleIntelligenceSource = "Apple Intelligence"
    /// Source label for the rule-based text.
    static let builtInSource = "Built-in tips"

    /// Writes the coaching text for `report`.
    /// - Returns: the text (bullets, one per line) and where it came from.
    static func write(report: AnalysisReport, projectTitle: String) async -> (text: String, source: String) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let prompt = makePrompt(report: report, projectTitle: projectTitle)
            if let text = await appleIntelligenceText(prompt: prompt) {
                return (text, appleIntelligenceSource)
            }
        }
        #endif
        return (fallbackText(report: report), builtInSource)
    }

    // MARK: Apple Intelligence

    private static let instructions = """
    You are a friendly, encouraging dance coach for a beginner who is learning \
    K-pop and hip-hop choreography from tutorial videos. \
    Give 4 to 6 short bullet tips, one per line, each starting with "- ". \
    When 8-count numbers or counts are given, mention them (for example "In 8-count 3, on count 5"). \
    ONLY use the measurements you are given. Never invent moves, body parts or details. \
    Do not make medical claims or mention injuries. \
    Use plain, simple English and keep it positive.
    """

    #if canImport(FoundationModels)
    /// Asks the on-device model. Returns nil if it is not available or fails.
    @available(iOS 26.0, *)
    private static func appleIntelligenceText(prompt: String) async -> String? {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return nil }
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            // Guardrails, context too long, cancelled, ... -> use the built-in tips.
            return nil
        }
    }
    #endif

    /// A short summary of the measurements for the language model.
    static func makePrompt(report: AnalysisReport, projectTitle: String) -> String {
        var lines: [String] = []
        lines.append("Dance: \(projectTitle)")
        lines.append("Overall score: \(report.overallScore) out of 100 (higher = closer to the tutorial).")
        lines.append("Timing: \(timingSentence(report.timingOffset))")

        if report.topFindings.isEmpty {
            lines.append("Biggest differences: none found.")
        } else {
            lines.append("Biggest things to work on (most important first):")
            for (i, f) in report.topFindings.enumerated() {
                lines.append("\(i + 1). \(f.bodyPart): \(f.message) (\(f.whereText))")
            }
        }

        let weakest = report.segments.sorted { $0.score < $1.score }.prefix(3)
        if !weakest.isEmpty {
            lines.append("Weakest parts:")
            for s in weakest {
                var line = "- \(s.label): score \(s.score)"
                if abs(s.timingOffset) >= 0.15 {
                    let amount = String(format: "%.1f", abs(s.timingOffset))
                    let direction = s.timingOffset > 0 ? "late" : "early"
                    line += ", timing \(amount) s \(direction)"
                }
                let messages = s.findings.prefix(2).map { $0.message }
                if !messages.isEmpty { line += ", " + messages.joined(separator: "; ") }
                lines.append(line)
            }
        }

        lines.append("Write the tips now.")
        return lines.joined(separator: "\n")
    }

    private static func timingSentence(_ offset: Double) -> String {
        if abs(offset) < 0.08 { return "right on the beat." }
        let amount = String(format: "%.2f", abs(offset))
        return offset > 0 ? "about \(amount) s late on average." : "about \(amount) s early on average."
    }

    // MARK: Built-in tips

    /// Simple rule-based tips from the same measurements.
    static func fallbackText(report: AnalysisReport) -> String {
        var tips: [String] = []

        // One encouraging opening line, matched to the score.
        if report.overallScore >= 75 {
            tips.append("- Great work. You're very close to the tutorial!")
        } else if report.overallScore >= 50 {
            tips.append("- Nice progress. The basics are there, now let's polish the details.")
        } else {
            tips.append("- Every dancer starts here. Slow the tutorial down and take one 8-count at a time.")
        }

        // Timing.
        if abs(report.timingOffset) >= 0.08 {
            let amount = String(format: "%.2f", abs(report.timingOffset))
            if report.timingOffset > 0 {
                tips.append("- You're about \(amount) s behind the beat. Try to hit each count a little earlier.")
            } else {
                tips.append("- You're about \(amount) s ahead of the beat. Wait for each count a little longer.")
            }
        } else {
            tips.append("- Your timing is right on the beat. Keep it up!")
        }

        // The most important findings (timing is already covered above).
        let findings = report.topFindings.filter { $0.bodyPart != "Timing" }.prefix(3)
        for f in findings {
            let place = String(f.whereText.prefix(1)).uppercased() + String(f.whereText.dropFirst())
            tips.append("- \(place): \(f.message).")
        }

        tips.append("- Practice the weakest 8-count on its own at half speed, then bring it back up to full speed.")
        return tips.joined(separator: "\n")
    }
}
