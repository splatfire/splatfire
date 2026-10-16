import SwiftUI
import SwiftData

/// After a memory test (recording with the tutorial hidden): tick the
/// 8-counts you forgot. Those are marked "Still learning", the rest "Got it",
/// so the progress bar in the practice screen shows what to drill next.
@MainActor
struct MemoryResultSheet: View {
    let project: Project
    let take: Take

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var forgotten: Set<Int> = []

    init(project: Project, take: Take) {
        self.project = project
        self.take = take
    }

    /// The 8-counts the take covers.
    private var indexes: [Int] {
        let grid = CountGrid.unbounded(bpm: project.bpm, offset: project.offset)
        guard grid.isValid else { return [] }
        let first = grid.index(at: take.tutorialStart) ?? 0
        let last = grid.index(at: max(take.tutorialEnd - 0.05, take.tutorialStart)) ?? first
        let upper = project.eightCountTotal > 0 ? min(last, project.eightCountTotal - 1) : last
        return upper >= first ? Array(first...upper) : []
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(indexes, id: \.self) { index in
                        Button {
                            if forgotten.contains(index) {
                                forgotten.remove(index)
                            } else {
                                forgotten.insert(index)
                            }
                        } label: {
                            row(index)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Which 8-counts did you forget?")
                } footer: {
                    Text("Tap the ones you forgot or weren't sure of. They're marked \"Still learning\", the others \"Got it\". Watch the replay above to check.")
                }
            }
            .navigationTitle("Memory test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                    .disabled(indexes.isEmpty)
                }
            }
        }
    }

    private func row(_ index: Int) -> some View {
        let forgot = forgotten.contains(index)
        let note = NextMoveHint.text(of: project.note(for: index))
        return HStack(spacing: 12) {
            Image(systemName: forgot ? Mastery.learning.symbol : Mastery.known.symbol)
                .font(.title3)
                .foregroundStyle(forgot ? Theme.learning : Theme.known)
            VStack(alignment: .leading, spacing: 2) {
                Text("8-count \(index + 1)")
                    .font(.body.weight(.semibold))
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(forgot ? "Forgot" : "Got it")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(forgot ? Theme.learning : Theme.known)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(forgot ? "Forgot" : "Got it")
        .accessibilityHint("Tap to switch")
    }

    private func save() {
        for index in indexes {
            NoteStore.setMastery(forgotten.contains(index) ? .learning : .known,
                                 for: index, in: project, context: modelContext)
        }
    }
}
