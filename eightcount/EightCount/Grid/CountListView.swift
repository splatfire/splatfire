import SwiftUI
import SwiftData

/// The scrollable list of 8-counts under the video.
/// Tap a row to jump there, ⟳ to loop it, ✎ to write notes.
@MainActor
struct CountListView: View {
    let project: Project
    let grid: CountGrid
    /// The 8-count playing right now (nil before count 1).
    let currentIndex: Int?
    /// The 8-counts being looped (one, or a whole stretch), if any.
    let loopedRange: ClosedRange<Int>?
    /// Named sections, shown as headers above their first 8-count.
    let sections: [PracticeSection]
    /// The section whose 8-counts are looping right now.
    let loopedSectionID: UUID?
    /// When true, the list scrolls by itself to keep the current 8-count visible.
    let followPlayback: Bool
    let onJump: (Int) -> Void
    let onToggleLoop: (Int) -> Void
    let onEdit: (Int) -> Void
    let onSetupTempo: () -> Void
    let onLoopSection: (PracticeSection) -> Void
    /// Long-press menu: "New section from here".
    let onNewSection: (Int) -> Void
    /// Long-press menu: "Got it" / "Still learning" / clear.
    let onSetMastery: (Int, Mastery) -> Void
    /// Long-press menu: "Formation…".
    let onFormation: (Int) -> Void

    init(project: Project, grid: CountGrid, currentIndex: Int?, loopedRange: ClosedRange<Int>?,
         sections: [PracticeSection], loopedSectionID: UUID?, followPlayback: Bool,
         onJump: @escaping (Int) -> Void,
         onToggleLoop: @escaping (Int) -> Void,
         onEdit: @escaping (Int) -> Void,
         onSetupTempo: @escaping () -> Void,
         onLoopSection: @escaping (PracticeSection) -> Void,
         onNewSection: @escaping (Int) -> Void,
         onSetMastery: @escaping (Int, Mastery) -> Void,
         onFormation: @escaping (Int) -> Void) {
        self.project = project
        self.grid = grid
        self.currentIndex = currentIndex
        self.loopedRange = loopedRange
        self.sections = sections
        self.loopedSectionID = loopedSectionID
        self.followPlayback = followPlayback
        self.onJump = onJump
        self.onToggleLoop = onToggleLoop
        self.onEdit = onEdit
        self.onSetupTempo = onSetupTempo
        self.onLoopSection = onLoopSection
        self.onNewSection = onNewSection
        self.onSetMastery = onSetMastery
        self.onFormation = onFormation
    }

    var body: some View {
        // Look up notes by 8-count number once, not once per row.
        let notesByIndex = Self.noteLookup(project.notes)

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if grid.bpm > 0 {
                        tempoChip
                    }
                    if grid.isValid && grid.numberOfEightCounts > 0 {
                        progressBar(notesByIndex)
                    }
                    rows(notesByIndex)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 28)
            }
            .onChange(of: currentIndex) { _, newIndex in
                guard followPlayback, let newIndex else { return }
                scroll(proxy, to: newIndex)
            }
            .onChange(of: followPlayback) { _, isOn in
                guard isOn, let index = currentIndex else { return }
                scroll(proxy, to: index)
            }
            // A soft fade at the top, so rows slide away under the controls
            // instead of being cut off.
            .mask { topFade }
            .background(Theme.background)
        }
    }

    private var topFade: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [Color.black.opacity(0), Color.black],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 12)
            Rectangle().fill(Color.black)
        }
    }

    // MARK: - Pieces

    /// "♩ 120 BPM · count 1 at 0:00.50   Edit" — tap to open the tempo sheet.
    /// (Without a tempo the empty state below offers "Set Tempo" instead.)
    private var tempoChip: some View {
        HStack(spacing: 0) {
            Button(action: onSetupTempo) {
                HStack(spacing: 10) {
                    Text("♩ \(TempoTapper.displayString(for: grid.bpm)) BPM · count 1 at \(formatTime(grid.offset))")
                        .foregroundStyle(Color.white)
                    Text("Edit")
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.accent)
                }
                .font(.subheadline.weight(.medium).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 16)
                .frame(minHeight: Theme.controlHeight)
                .glassSurface(Capsule(), interactive: true, fallback: Theme.surface)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tempoAccessibilityText)
            Spacer(minLength: 0)
        }
    }

    private var tempoAccessibilityText: String {
        guard grid.bpm > 0 else { return "Tempo not set. Set tempo." }
        return "Tempo \(TempoTapper.displayString(for: grid.bpm)) BPM, count 1 at \(formatTime(grid.offset)). Edit."
    }

    @ViewBuilder
    private func rows(_ notesByIndex: [Int: CountNote]) -> some View {
        if grid.isValid && grid.numberOfEightCounts > 0 {
            ForEach(0..<grid.numberOfEightCounts, id: \.self) { index in
                ForEach(sections.filter { $0.startIndex == index }, id: \.id) { section in
                    sectionHeader(section)
                }
                CountRowView(
                    index: index,
                    startTime: grid.start(of: index),
                    note: notesByIndex[index],
                    isCurrent: currentIndex == index,
                    isLooped: loopedRange?.contains(index) ?? false,
                    mastery: notesByIndex[index]?.mastery ?? .unmarked,
                    onJump: { onJump(index) },
                    onToggleLoop: { onToggleLoop(index) },
                    onEdit: { onEdit(index) }
                )
                .contextMenu {
                    let current = notesByIndex[index]?.mastery ?? .unmarked
                    ForEach([Mastery.known, .learning], id: \.self) { level in
                        Button {
                            onSetMastery(index, current == level ? .unmarked : level)
                        } label: {
                            Label(current == level ? "Clear \"\(level.title)\"" : level.title,
                                  systemImage: level.symbol)
                        }
                    }
                    Divider()
                    Button {
                        onFormation(index)
                    } label: {
                        Label("Formation…", systemImage: "person.3")
                    }
                    Button {
                        onNewSection(index)
                    } label: {
                        Label("New Section from Here…", systemImage: "rectangle.stack.badge.plus")
                    }
                }
                .id(index)
            }
        } else if grid.bpm > 0 && grid.duration <= 0 {
            // BPM is set, we're just waiting for the video's length.
            ProgressView("Loading video…")
                .padding(.top, 40)
        } else if grid.isValid {
            // BPM is set but count 1 is at/after the end of the video.
            messageState(
                icon: "backward.end.fill",
                title: "Count 1 is after the end",
                message: "Count 1 is set to \(formatTime(grid.offset)), but the video is only \(formatTime(grid.duration)) long. Move the start of count 1 earlier.",
                buttonTitle: "Fix Start of Count 1"
            )
        } else {
            messageState(
                icon: "music.quarternote.3",
                title: "Find the beat",
                message: "Set the song's tempo, or tap along, to split the video into 8-counts.",
                buttonTitle: "Set Tempo"
            )
        }
    }

    /// "Got it: 5 of 12" with a bar, plus how many are still being learned.
    /// Mark 8-counts with a long press (or after a memory test).
    private func progressBar(_ notesByIndex: [Int: CountNote]) -> some View {
        let total = grid.numberOfEightCounts
        let known = (0..<total).filter { notesByIndex[$0]?.mastery == .known }.count
        let learning = (0..<total).filter { notesByIndex[$0]?.mastery == .learning }.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(known == total ? "You know the whole dance!" : "Got it: \(known) of \(total)")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if learning > 0 {
                    Label("\(learning) still learning", systemImage: Mastery.learning.symbol)
                        .font(.caption)
                        .foregroundStyle(Theme.learning)
                }
            }
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule().fill(Theme.learning.opacity(0.6))
                        .frame(width: width * CGFloat(known + learning) / CGFloat(max(total, 1)))
                    Capsule().fill(Theme.known)
                        .frame(width: width * CGFloat(known) / CGFloat(max(total, 1)))
                }
            }
            .frame(height: 6)
            if known + learning == 0 {
                Text("Long-press an 8-count to mark it \"Got it\".")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .animation(.snappy, value: known)
    }

    /// "CHORUS · 8-counts 9–16  ⟳" above a section's first 8-count.
    private func sectionHeader(_ section: PracticeSection) -> some View {
        let isLooping = loopedSectionID == section.id
        return HStack(spacing: 8) {
            Text(section.name.uppercased())
                .font(.system(.caption, design: .rounded).weight(.bold))
                .tracking(0.8)
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
            Text(section.rangeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
            Button {
                onLoopSection(section)
            } label: {
                Label(isLooping ? "Looping" : "Loop", systemImage: "repeat")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isLooping ? Color.black : Theme.loopColor)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 30)
                    .background(Capsule().fill(isLooping ? Theme.loopColor : Theme.loopColor.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isLooping ? "Stop looping \(section.name)" : "Loop \(section.name)")
        }
        .padding(.top, 6)
    }

    /// Calm, centered empty state: soft icon circle, short text, one button.
    private func messageState(icon: String, title: String, message: String, buttonTitle: String) -> some View {
        VStack(spacing: Theme.spacingM) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Theme.accent)
                .frame(width: 72, height: 72)
                .background(Circle().fill(Theme.accent.opacity(0.14)))
                .padding(.bottom, 4)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onSetupTempo) {
                Text(buttonTitle)
            }
            .buttonStyle(AccentCapsuleButtonStyle())
            .padding(.top, Theme.spacingS)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private func scroll(_ proxy: ScrollViewProxy, to index: Int) {
        withAnimation(.easeInOut(duration: 0.3)) {
            proxy.scrollTo(index, anchor: .center)
        }
    }

    /// [8-count number: note]. If there are ever two notes for the same
    /// 8-count (shouldn't happen), prefer the one with content.
    private static func noteLookup(_ notes: [CountNote]) -> [Int: CountNote] {
        var lookup: [Int: CountNote] = [:]
        for note in notes {
            if let existing = lookup[note.countIndex], !existing.isEmpty {
                continue
            }
            lookup[note.countIndex] = note
        }
        return lookup
    }
}
