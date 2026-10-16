import Observation
import SwiftUI
import UIKit

/// "Save video": pick what to save, then it goes to the camera roll
/// (so you can post it on TikTok). Present it as a sheet.
@MainActor
struct ExportTakeSheet: View {
    private let snapshot: TakeSnapshot

    @Environment(\.dismiss) private var dismiss

    @State private var model = ExportModel()
    @State private var option: ExportOption
    /// Only shown when you practiced slower than the tutorial.
    @State private var realTempo = true
    @State private var mirrored = false
    /// "Me + tutorial": start with the same flips as the compare screen, so
    /// the saved video looks like what you compared.
    @State private var mirrorMe: Bool
    @State private var mirrorTutorial: Bool

    /// Read the take's values now (on the main actor) and keep plain copies.
    init(take: Take, project: Project, mirrorMe: Bool = true, mirrorTutorial: Bool = false) {
        self.init(snapshot: TakeSnapshot(take: take, tutorialURL: project.videoURL),
                  mirrorMe: mirrorMe, mirrorTutorial: mirrorTutorial)
    }

    init(snapshot: TakeSnapshot, mirrorMe: Bool = true, mirrorTutorial: Bool = false) {
        self.snapshot = snapshot
        _option = State(initialValue: snapshot.tutorialURL == nil ? .original : .meWithSong)
        _mirrorMe = State(initialValue: mirrorMe)
        _mirrorTutorial = State(initialValue: mirrorTutorial)
    }

    private var hasTutorial: Bool { snapshot.tutorialURL != nil }
    private var practicedSlower: Bool { snapshot.timing.recordRate < 0.999 }

    private var kind: TakeExportKind {
        switch option {
        case .meWithSong: return .meWithSong(realTempo: realTempo || !practicedSlower, mirrored: mirrored)
        case .sideBySide: return .sideBySide(realTempo: realTempo || !practicedSlower,
                                             mirrorMe: mirrorMe, mirrorTutorial: mirrorTutorial)
        case .original: return .original
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                switch model.phase {
                case .saved:
                    savedView
                default:
                    optionsView
                }
            }
        }
        .background(Theme.background)
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.background)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(model.isWorking)
        .preferredColorScheme(.dark)
        .onDisappear { model.cancel() }
    }

    // MARK: - Header (always visible)

    private var header: some View {
        HStack {
            Text("Save video")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(Color.white)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                model.cancel()
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.round(size: 40))
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, Theme.spacingL)
        .padding(.top, 22)
        .padding(.bottom, Theme.spacingM)
    }

    // MARK: - Options

    private var optionsView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: Theme.spacingM) {
                    optionCard(.meWithSong) {
                        if practicedSlower {
                            Toggle(isOn: $realTempo) {
                                toggleLabel("Real tempo",
                                            "Speeds you up to match the original song.")
                            }
                            .tint(Theme.accent)
                        }
                        Toggle(isOn: $mirrored) {
                            toggleLabel("Mirror (as you saw yourself)",
                                        "Flips the picture left to right.")
                        }
                        .tint(Theme.accent)
                    }

                    optionCard(.sideBySide) {
                        if practicedSlower {
                            Toggle(isOn: $realTempo) {
                                toggleLabel("Real tempo",
                                            "Both videos play at the original song's speed.")
                            }
                            .tint(Theme.accent)
                        }
                        Toggle(isOn: $mirrorMe) {
                            toggleLabel("Mirror me", "Flips your video left to right.")
                        }
                        .tint(Theme.accent)
                        Toggle(isOn: $mirrorTutorial) {
                            toggleLabel("Mirror tutorial", "Flips the tutorial left to right.")
                        }
                        .tint(Theme.accent)
                        Text("Set like the compare screen, so moves on the same side line up.")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("Only post the tutorial if you have the rights to it.")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)

                    optionCard(.original) { EmptyView() }
                }
                .padding(.horizontal, Theme.spacingL)
                .padding(.bottom, Theme.spacingM)
            }
            .disabled(model.isWorking)

            bottomBar
        }
    }

    private func toggleLabel(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.white)
            Text(detail)
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    @ViewBuilder
    private func optionCard<Extra: View>(_ value: ExportOption,
                                         @ViewBuilder extras: () -> Extra) -> some View {
        let selected = option == value
        let available = !value.needsTutorial || hasTutorial
        VStack(alignment: .leading, spacing: Theme.spacingM) {
            Button {
                option = value
            } label: {
                HStack(spacing: Theme.spacingM) {
                    Image(systemName: value.symbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(selected ? Theme.accent : Color.white)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(value.title)
                            .font(.system(.headline, design: .rounded))
                            .foregroundStyle(Color.white)
                        Text(available ? value.detail : "This project has no tutorial video.")
                            .font(.system(.footnote, design: .rounded))
                            .foregroundStyle(Theme.secondaryText)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 24))
                        .foregroundStyle(selected ? Theme.accent : Theme.secondaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!available)
            .accessibilityLabel(value.title)
            .accessibilityAddTraits(selected ? .isSelected : [])

            if selected && available {
                extras()
            }
        }
        .card(highlighted: selected && available)
        .opacity(available ? 1 : 0.5)
    }

    // MARK: - Bottom bar (Save / progress)

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: Theme.spacingM) {
            switch model.phase {
            case .exporting, .saving:
                progressView
            default:
                if let message = model.errorMessage {
                    Text(message)
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(Color.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    model.start(snapshot: snapshot, kind: kind)
                } label: {
                    Text("Save to Photos")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(Color.black)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(Capsule().fill(Theme.accent))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(option.needsTutorial && !hasTutorial)
                .accessibilityLabel("Save to Photos")
            }
        }
        .padding(.horizontal, Theme.spacingL)
        .padding(.top, Theme.spacingM)
        .padding(.bottom, Theme.spacingL)
    }

    private var progressView: some View {
        VStack(spacing: Theme.spacingM) {
            if model.phase == .exporting {
                ProgressView(value: model.progress)
                    .tint(Theme.accent)
                Text("Preparing video\u{2026} \(Int((model.progress * 100).rounded()))%")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.white)
            } else {
                ProgressView()
                    .tint(Theme.accent)
                Text("Saving to Photos\u{2026}")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.white)
            }
            if model.phase == .exporting {
                Button {
                    model.cancel()
                } label: {
                    Text("Cancel")
                }
                .buttonStyle(.big)
                .accessibilityLabel("Cancel")
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Done

    private var savedView: some View {
        VStack(spacing: Theme.spacingL) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 84))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text("Saved to Photos")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(Color.white)
            Text("It is in your Photos app, ready to post.")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
            VStack(spacing: Theme.spacingM) {
                Button {
                    openTikTok()
                } label: {
                    Text("Open TikTok")
                }
                .buttonStyle(.big(isOn: true))
                .accessibilityLabel("Open TikTok")

                Button {
                    dismiss()
                } label: {
                    Text("Done")
                }
                .buttonStyle(.big)
                .accessibilityLabel("Done")
            }
        }
        .padding(.horizontal, Theme.spacingL)
        .padding(.bottom, Theme.spacingL)
        .accessibilityElement(children: .contain)
    }

    /// We just try to open it; if TikTok isn't installed, nothing happens.
    private func openTikTok() {
        guard let url = URL(string: "tiktok://") else { return }
        Task { @MainActor in
            _ = await UIApplication.shared.open(url)
        }
    }
}

// MARK: - Options

private enum ExportOption: String, Identifiable {
    case meWithSong, sideBySide, original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meWithSong: return "Me with the song"
        case .sideBySide: return "Me + tutorial"
        case .original: return "Original recording"
        }
    }

    var detail: String {
        switch self {
        case .meWithSong: return "Your video with the tutorial's music, starting where the music starts."
        case .sideBySide: return "Vertical 9:16 video: you on top, the tutorial below, with the music."
        case .original: return "The raw recording, without sound."
        }
    }

    var symbol: String {
        switch self {
        case .meWithSong: return "music.note"
        case .sideBySide: return "rectangle.split.1x2"
        case .original: return "video"
        }
    }

    var needsTutorial: Bool { self != .original }
}

// MARK: - Export state

@MainActor
@Observable
private final class ExportModel {
    enum Phase: Equatable {
        case idle, exporting, saving, saved
    }

    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0
    private(set) var errorMessage: String?

    private var task: Task<Void, Never>?

    var isWorking: Bool { phase == .exporting || phase == .saving }

    func start(snapshot: TakeSnapshot, kind: TakeExportKind) {
        guard !isWorking else { return }
        errorMessage = nil
        progress = 0
        phase = kind.needsTutorial ? .exporting : .saving

        task = Task { [weak self] in
            var exported: URL?
            do {
                // Ask for permission first, so a "No" doesn't waste a long export.
                try await TakeExporter.requestPhotosAccess()
                let url = try await TakeExporter.export(take: snapshot, kind: kind) { value in
                    Task { @MainActor [weak self] in
                        guard let self, self.phase == .exporting else { return }
                        self.progress = min(max(value, 0), 1)
                    }
                }
                exported = url
                try Task.checkCancellation()
                self?.phase = .saving
                try await TakeExporter.saveToPhotos(url)   // also deletes the temp file
                exported = nil
                self?.phase = .saved
            } catch is CancellationError {
                self?.phase = .idle
            } catch {
                self?.errorMessage = error.localizedDescription
                self?.phase = .idle
            }
            if let exported {
                try? FileManager.default.removeItem(at: exported)
            }
            self?.task = nil
        }
    }

    func cancel() {
        task?.cancel()
        if isWorking { phase = .idle }
    }
}
