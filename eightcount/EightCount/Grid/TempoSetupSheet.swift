import SwiftUI
import SwiftData

/// Sheet to set the song's tempo (BPM) and where count 1 starts.
/// Together these split the video into 8-counts.
@MainActor
struct TempoSetupSheet: View {
    @Bindable var project: Project
    /// Reads the video's current time (seconds) when called.
    let currentTime: () -> Double
    /// The speed the video plays at (1 = normal, 0.5 = half speed).
    let playbackRate: Double
    /// Moves the video to a time (seconds).
    let onSeek: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var bpmText = ""
    @State private var tapper: TempoTapper
    @FocusState private var bpmFieldFocused: Bool
    /// Automatic beat detection: running / result / error.
    @State private var isDetecting = false
    @State private var detected: BeatDetector.Result?
    @State private var detectError: String?

    init(project: Project,
         currentTime: @escaping () -> Double,
         playbackRate: Double,
         onSeek: @escaping (Double) -> Void) {
        self._project = Bindable(wrappedValue: project)
        self.currentTime = currentTime
        self.playbackRate = playbackRate
        self.onSeek = onSeek
        // At slow speed the beats are further apart, so wait longer before
        // a pause counts as "starting over".
        let safeRate = playbackRate > 0 && playbackRate.isFinite ? playbackRate : 1
        self._tapper = State(initialValue: TempoTapper(resetInterval: max(2, 2 / safeRate)))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    autoCard
                    bpmCard
                    tapCard
                    offsetCard
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.background)
            .navigationTitle("Tempo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        bpmFieldFocused = false
                        dismiss()
                    }
                    .font(.headline)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Set BPM") { bpmFieldFocused = false }
                        .font(.headline)
                }
            }
        }
        .onAppear { syncTextFromProject() }
        // Typing: apply as soon as the number is valid.
        .onChange(of: bpmText) { _, newValue in
            applyTyped(newValue)
        }
        // Leaving the text field: show the real value again (drops invalid input).
        .onChange(of: bpmFieldFocused) { _, focused in
            if !focused { syncTextFromProject() }
        }
        // BPM changed by a button: update the text field.
        .onChange(of: project.bpm) { _, _ in
            if !bpmFieldFocused { syncTextFromProject() }
        }
        .onDisappear { try? modelContext.save() }
    }

    // MARK: - 0. Automatic

    private var autoCard: some View {
        card("Find it for me", systemImage: "waveform") {
            Button {
                Task { await detect() }
            } label: {
                HStack(spacing: 10) {
                    if isDetecting {
                        ProgressView().tint(.white)
                        Text("Listening to the song…")
                    } else {
                        Label(detected == nil ? "Find the beat" : "Find it again", systemImage: "sparkles")
                    }
                }
            }
            .buttonStyle(.big(isOn: true))
            .disabled(isDetecting || project.videoURL == nil)

            if let detected {
                Text(detected.isSure
                     ? "Found \(TempoTapper.displayString(for: detected.bpm)) BPM, count 1 at \(formatTime(detected.firstDownbeat))."
                     : "Found \(TempoTapper.displayString(for: detected.bpm)) BPM, count 1 at \(formatTime(detected.firstDownbeat)) – but I'm not sure.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(detected.isSure ? Theme.known : Theme.learning)
                    .accessibilityIdentifier("beatResult")
                HStack(spacing: 8) {
                    Button("½ tempo") { setBPM(project.bpm / 2) }
                        .buttonStyle(.big)
                    Button("2× tempo") { setBPM(project.bpm * 2) }
                        .buttonStyle(.big)
                }
                HStack(spacing: 8) {
                    shiftButton(-4, label: "−4 counts")
                    shiftButton(-1, label: "−1 count")
                    shiftButton(1, label: "+1 count")
                    shiftButton(4, label: "+4 counts")
                }
                helpText("Play from count 1 and count along. Beat too fast or slow? Use ½ / 2×. \"1\" lands on a \"5\" or off by one? Move count 1 with the buttons.")
            } else if let detectError {
                helpText(detectError, color: Theme.learning)
            } else {
                helpText("The app listens to the video's music and sets the BPM and count 1. Works best with a clear drum beat. Check it afterwards.")
            }
        }
    }

    /// Moves count 1 by whole beats.
    private func shiftButton(_ beats: Int, label: String) -> some View {
        Button {
            guard project.bpm > 0 else { return }
            var newOffset = project.offset + Double(beats) * 60 / project.bpm
            if newOffset < 0 { newOffset += 8 * 60 / project.bpm }
            setOffset(newOffset)
        } label: {
            Text(label).font(.footnote.weight(.semibold)).monospacedDigit()
        }
        .buttonStyle(.big)
        .accessibilityLabel(beats > 0 ? "Move count 1 later by \(beats)" : "Move count 1 earlier by \(-beats)")
    }

    private func detect() async {
        guard let url = project.videoURL else { return }
        isDetecting = true
        detectError = nil
        defer { isDetecting = false }
        do {
            let result = try await BeatDetector.detect(url: url)
            detected = result
            setBPM(result.bpm)
            // setOffset rounds to 1/100 s, like the nudge buttons.
            setOffset(result.firstDownbeat)
        } catch {
            detected = nil
            detectError = error.localizedDescription
        }
    }

    // MARK: - 1. BPM

    private var bpmCard: some View {
        card("Song tempo", systemImage: "metronome") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(project.bpm > 0 ? TempoTapper.displayString(for: project.bpm) : "–")
                    .font(.system(size: 56, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(project.bpm > 0 ? Color.white : Theme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("BPM")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
                Spacer(minLength: 8)
                TextField("Type", text: $bpmText)
                    .keyboardType(.decimalPad)
                    .focused($bpmFieldFocused)
                    .multilineTextAlignment(.center)
                    .font(.title2.monospacedDigit())
                    .frame(width: 104, height: Theme.tapHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.surfaceRaised)
                    )
                    .accessibilityLabel("Type the BPM")
            }

            HStack(spacing: 8) {
                adjustButton(-1, label: "−1")
                adjustButton(-0.5, label: "−0.5")
                adjustButton(0.5, label: "+0.5")
                adjustButton(1, label: "+1")
            }

            helpText("Between 40 and 250. Don't know it? Search the web for “<song name> BPM”, or tap along below.")
        }
    }

    private func adjustButton(_ delta: Double, label: String) -> some View {
        let spoken: String = delta > 0
            ? "Increase BPM by \(TempoTapper.displayString(for: delta))"
            : "Decrease BPM by \(TempoTapper.displayString(for: -delta))"
        return Button {
            // Start from 120 if no tempo has been set yet.
            let base = project.bpm > 0 ? project.bpm : 120
            setBPM(base + delta)
        } label: {
            Text(label).monospacedDigit()
        }
        .buttonStyle(.big)
        .accessibilityLabel(spoken)
    }

    // MARK: - 2. Tap along

    /// Your tapped BPM corrected for the playback speed (rounded), or nil.
    private var songBPMFromTaps: Double? {
        guard let tapped = tapper.bpm else { return nil }
        return TempoTapper.rounded(tapped / rate)
    }

    private var tapStatus: String {
        switch tapper.tapCount {
        case 0: return "Tap on every beat"
        case 1: return "Keep tapping…"
        default:
            guard let tapped = tapper.bpm else { return "Keep tapping…" }
            return "\(TempoTapper.displayString(for: tapped)) BPM · \(tapper.tapCount) taps"
        }
    }

    private var tapCard: some View {
        card("Or tap along", systemImage: "hand.tap") {
            Button {
                tapper.tap()
            } label: {
                VStack(spacing: 6) {
                    Text("TAP")
                        .font(.system(size: 44, weight: .heavy, design: .rounded))
                    Text(tapStatus)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
                .frame(maxWidth: .infinity, minHeight: 132)
                .contentShape(Rectangle())
            }
            .buttonStyle(TapPadStyle())
            .sensoryFeedback(.impact(weight: .light), trigger: tapper.tapCount)
            .accessibilityHint("Tap on every beat of the music")

            if let songBPM = songBPMFromTaps, rate != 1 {
                Text("At \(rateText)× speed you tapped \(TempoTapper.displayString(for: tapper.bpm ?? 0)) → the song is \(TempoTapper.displayString(for: songBPM)) BPM")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white)
            }

            HStack(spacing: 8) {
                Button {
                    tapper.reset()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.big)
                .frame(maxWidth: 130)

                Button {
                    if let songBPM = songBPMFromTaps { setBPM(songBPM) }
                } label: {
                    if let songBPM = songBPMFromTaps {
                        Text("Use \(TempoTapper.displayString(for: songBPM)) BPM")
                    } else {
                        Text("Use this BPM")
                    }
                }
                .buttonStyle(.big(isOn: tapResultIsUsable))
                .disabled(!tapResultIsUsable)
            }

            if let songBPM = songBPMFromTaps, !TempoTapper.validRange.contains(songBPM) {
                helpText("That's outside 40–250. Try tapping on every beat — not every other one, and not twice per beat.",
                         color: Theme.accent)
            }

            helpText("Tip: play the video and tap on every beat; start on a strong beat. 8 or more taps give a steadier number.")
            if rate != 1 {
                helpText("The video is playing at \(rateText)× speed, so your taps don't match the real song's speed. The app divides your tapped BPM by \(rateText) to get the real BPM.")
            }
        }
    }

    /// The playback speed, treating nonsense values as normal speed.
    private var rate: Double {
        playbackRate > 0 && playbackRate.isFinite ? playbackRate : 1
    }

    private var tapResultIsUsable: Bool {
        guard let songBPM = songBPMFromTaps else { return false }
        return TempoTapper.validRange.contains(songBPM)
    }

    /// "0.5", "0.75", "1"
    private var rateText: String {
        let value = (rate * 100).rounded() / 100
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%g", value)
    }

    // MARK: - 3. Where count 1 starts

    private var offsetCard: some View {
        card("Start of count 1", systemImage: "flag") {
            Text(formatTime(project.offset))
                .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())

            Button {
                setOffset(currentTime())
            } label: {
                Label("Count 1 starts NOW", systemImage: "flag.fill")
            }
            .buttonStyle(.big(isOn: true))

            HStack(spacing: 8) {
                nudgeButton(-0.05, label: "−0.05")
                nudgeButton(-0.01, label: "−0.01")
                nudgeButton(0.01, label: "+0.01")
                nudgeButton(0.05, label: "+0.05")
            }

            Button {
                onSeek(project.offset)
            } label: {
                Label("Jump to count 1", systemImage: "backward.end.fill")
            }
            .buttonStyle(.big)

            helpText("Play the video and press “Count 1 starts NOW” on the first beat of the dance (often the first big move after the intro). Then fine-tune with the small buttons (seconds): the highlighted 8-count should change exactly on count 1.")
        }
    }

    private func nudgeButton(_ delta: Double, label: String) -> some View {
        let spoken: String = delta > 0
            ? "Move count 1 later by \(abs(delta)) seconds"
            : "Move count 1 earlier by \(abs(delta)) seconds"
        return Button {
            setOffset(project.offset + delta)
        } label: {
            Text(label).monospacedDigit()
        }
        .buttonStyle(.big)
        .accessibilityLabel(spoken)
    }

    // MARK: - Changes

    private func setBPM(_ value: Double) {
        guard value.isFinite else { return }
        let clamped = min(max(TempoTapper.rounded(value), TempoTapper.validRange.lowerBound),
                          TempoTapper.validRange.upperBound)
        guard clamped != project.bpm else { return }
        project.bpm = clamped
        project.updatedAt = .now
    }

    private func setOffset(_ value: Double) {
        guard value.isFinite else { return }
        // Round to 1/100 s so the nudge buttons don't build up float noise.
        let clamped = max(0, (value * 100).rounded() / 100)
        guard clamped != project.offset else { return }
        project.offset = clamped
        project.updatedAt = .now
    }

    /// Applies typed text if it is a valid BPM (accepts "," as decimal separator).
    private func applyTyped(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(cleaned), TempoTapper.validRange.contains(value) else { return }
        setBPM(value)
    }

    private func syncTextFromProject() {
        bpmText = project.bpm > 0 ? TempoTapper.displayString(for: project.bpm) : ""
    }

    // MARK: - Building blocks

    private func card<Content: View>(_ title: String, systemImage: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(Theme.secondaryText)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.surface)
        )
    }

    private func helpText(_ text: String, color: Color = Theme.secondaryText) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The big pink TAP pad.
private struct TapPadStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.black)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Theme.accent.opacity(configuration.isPressed ? 0.65 : 1))
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
