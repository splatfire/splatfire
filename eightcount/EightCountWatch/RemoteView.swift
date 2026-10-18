import SwiftUI
import WatchKit

/// The one screen of the watch app: 8-count, play/pause, back/next 8-count,
/// speed (tap or turn the Digital Crown) and loop.
struct RemoteView: View {
    let link: PhoneLink

    /// Index into `RemoteState.speeds`, driven by the Digital Crown.
    @State private var crown: Double = 3

    private static let accent = Color(red: 1.0, green: 0.30, blue: 0.40)
    private static let loopColor = Color(red: 0.35, green: 0.80, blue: 1.0)

    var body: some View {
        let state = link.state
        VStack(spacing: 6) {
            header(state)
            if state.active {
                controls(state)
            } else {
                Text(state.message ?? "Open a project on your iPhone.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity)
                Button("Try again") { link.refresh() }
            }
            if let problem = link.problem {
                Text(problem)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 2)
        .focusable(state.active)
        .digitalCrownRotation($crown, from: 0, through: Double(RemoteState.speeds.count - 1),
                              by: 1, sensitivity: .low, isContinuous: false,
                              isHapticFeedbackEnabled: true)
        .onChange(of: crown) { _, newValue in
            let index = Int(newValue.rounded())
            guard link.state.active, RemoteState.speeds.indices.contains(index),
                  index != speedIndex(link.state.rate) else { return }
            press(.setRate(RemoteState.speeds[index]))
        }
        .onChange(of: state.rate) { _, rate in
            crown = Double(speedIndex(rate))
        }
        .onAppear { crown = Double(speedIndex(state.rate)) }
    }

    // MARK: - Parts

    private func header(_ state: RemoteState) -> some View {
        VStack(spacing: 0) {
            Text(state.active ? (state.count ?? state.screen) : "EightCount")
                .font(.system(.title3, design: .rounded).weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(state.active ? "\(state.screen) · \(state.title)" : state.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func controls(_ state: RemoteState) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                iconButton("backward.end.fill", label: "Back one 8-count") { press(.back) }
                Button {
                    press(.playPause)
                } label: {
                    Image(systemName: state.playing ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .tint(Self.accent)
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(state.playing ? "Pause" : "Play")
                iconButton("forward.end.fill", label: "Next 8-count") { press(.forward) }
            }
            HStack(spacing: 6) {
                Button {
                    // Tap: next speed (after 2× it starts over at 0.25×).
                    let next = (speedIndex(state.rate) + 1) % RemoteState.speeds.count
                    press(.setRate(RemoteState.speeds[next]))
                } label: {
                    Text(RemoteState.speedLabel(state.rate))
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Speed \(RemoteState.speedLabel(state.rate))")

                Button {
                    press(.toggleLoop)
                } label: {
                    Image(systemName: "repeat")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .tint(state.looping ? Self.loopColor : nil)
                .foregroundStyle(state.looping ? Self.loopColor : Color.primary)
                .accessibilityLabel(state.looping ? "Loop on" : "Loop off")
            }
        }
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(label)
    }

    // MARK: - Helpers

    private func press(_ command: RemoteCommand) {
        WKInterfaceDevice.current().play(.click)
        link.send(command)
    }

    private func speedIndex(_ rate: Float) -> Int {
        RemoteState.speeds.firstIndex { abs($0 - rate) < 0.01 } ?? 3
    }
}
