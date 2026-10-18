import SwiftUI
import SwiftData

/// Everything for drilling a dance, in one sheet (the ✦ button on the video):
/// the coach (build up / speed ladder), memory test, next-move hint, the
/// spoken cues, and named sections.
@MainActor
struct PracticeToolsSheet: View {
    let project: Project
    let grid: CountGrid
    /// The 8-count at the playhead (nil in the intro).
    let currentIndex: Int?
    @Binding var memoryTest: Bool
    @Binding var showNextMove: Bool
    @Binding var showFormation: Bool
    @Binding var cues: CountCues.Settings
    /// Starts the coach on 8-counts first…last.
    let onBuildUp: (_ first: Int, _ last: Int, _ runs: Int, _ name: String?) -> Void
    let onSpeedLadder: (_ first: Int, _ last: Int, _ runs: Int, _ name: String?) -> Void
    let onLoopSection: (PracticeSection) -> Void
    /// Whether the spoken numbers are ready yet.
    let voiceStatus: CountCues.VoiceStatus

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @AppStorage("coachRuns") private var runs = 2
    @AppStorage("coachLength") private var length = 4
    /// Which part the coach drills: nil = "from the current 8-count".
    @State private var partID: UUID?
    @State private var editingSection: SectionDraft?

    init(project: Project, grid: CountGrid, currentIndex: Int?,
         memoryTest: Binding<Bool>, showNextMove: Binding<Bool>, showFormation: Binding<Bool>,
         cues: Binding<CountCues.Settings>,
         onBuildUp: @escaping (_ first: Int, _ last: Int, _ runs: Int, _ name: String?) -> Void,
         onSpeedLadder: @escaping (_ first: Int, _ last: Int, _ runs: Int, _ name: String?) -> Void,
         onLoopSection: @escaping (PracticeSection) -> Void,
         voiceStatus: CountCues.VoiceStatus) {
        self.project = project
        self.grid = grid
        self.currentIndex = currentIndex
        _memoryTest = memoryTest
        _showNextMove = showNextMove
        _showFormation = showFormation
        _cues = cues
        self.onBuildUp = onBuildUp
        self.onSpeedLadder = onSpeedLadder
        self.onLoopSection = onLoopSection
        self.voiceStatus = voiceStatus
    }

    private var count: Int { grid.isValid ? grid.numberOfEightCounts : 0 }
    private var hereStart: Int { min(currentIndex ?? 0, max(count - 1, 0)) }

    var body: some View {
        NavigationStack {
            Form {
                coachSection
                Section {
                    Toggle(isOn: $memoryTest) {
                        Label("Hide the video", systemImage: "eye.slash")
                    }
                } header: {
                    Text("Memory test")
                } footer: {
                    Text("Covers the video so you dance from memory. The music and the count keep going. Touch and hold the video to peek.")
                }
                Section {
                    Toggle(isOn: $showNextMove) {
                        Label("Show the next move", systemImage: "text.badge.chevron.right")
                    }
                    Toggle(isOn: $showFormation) {
                        Label("Show the formation", systemImage: "person.3")
                    }
                } header: {
                    Text("On the video")
                } footer: {
                    Text("The next move: the note of the coming 8-count. The formation: where everyone stands (long-press an 8-count → Formation… to draw it).")
                }
                cuesSection
                sectionsSection
            }
            .navigationTitle("Practice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editingSection) { draft in
                SectionEditorSheet(draft: draft, count: count) { saved in
                    save(saved)
                }
            }
        }
    }

    // MARK: - Coach

    @ViewBuilder
    private var coachSection: some View {
        Section {
            if count > 0 {
                Picker("Part", selection: $partID) {
                    Text("From 8-count \(hereStart + 1)").tag(UUID?.none)
                    ForEach(project.sortedSections, id: \.id) { section in
                        Text(section.name).tag(Optional(section.id))
                    }
                }
                if partID == nil {
                    Stepper(value: $length, in: 2...16) {
                        Text("\(length) 8-counts (\(hereStart + 1)–\(min(hereStart + length, count)))")
                            .monospacedDigit()
                    }
                }
                Stepper(value: $runs, in: 1...6) {
                    Text(runs == 1 ? "Each step once" : "Each step \(runs) times")
                        .monospacedDigit()
                }
                Button {
                    let part = chosenPart
                    onBuildUp(part.first, part.last, runs, part.name)
                    dismiss()
                } label: {
                    coachLabel("Build up", detail: "1, then 1–2, then 1–3 … then the whole part",
                               icon: "square.stack.3d.up")
                }
                Button {
                    let part = chosenPart
                    onSpeedLadder(part.first, part.last, runs, part.name)
                    dismiss()
                } label: {
                    coachLabel("Speed ladder", detail: "½× → ¾× → full speed",
                               icon: "gauge.with.dots.needle.33percent")
                }
            } else {
                Text("Set the tempo first (the bar above the 8-count list), so the app knows where each 8-count is.")
                    .foregroundStyle(Theme.secondaryText)
            }
        } header: {
            Text("Coach")
        } footer: {
            if count > 0 {
                Text("The part loops and moves on by itself after each step's runs.")
            }
        }
    }

    private func coachLabel(_ title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(Color.primary)
                Text(detail).font(.caption).foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private var chosenPart: (first: Int, last: Int, name: String?) {
        if let partID, let section = project.sections.first(where: { $0.id == partID }) {
            let first = min(section.startIndex, max(count - 1, 0))
            return (first, min(section.endIndex, max(count - 1, 0)), section.name)
        }
        return (hereStart, min(hereStart + length - 1, max(count - 1, 0)), nil)
    }

    // MARK: - Cues

    private var cuesSection: some View {
        Section {
            Toggle(isOn: $cues.countIn) {
                Label("Count-in \"5, 6, 7, 8\"", systemImage: "megaphone")
            }
            if cues.countIn {
                Toggle(isOn: $cues.countInEveryLoop) {
                    Label("Before every loop too", systemImage: "repeat")
                }
            }
            Toggle(isOn: $cues.click) {
                Label("Beat click", systemImage: "metronome")
            }
            Toggle(isOn: $cues.sayCounts) {
                Label("Say the counts", systemImage: "number")
            }
            Toggle(isOn: $cues.sayMoves) {
                Label("Say my moves", systemImage: "text.bubble")
            }
            Toggle(isOn: $cues.fade) {
                Label("Fade as I repeat", systemImage: "speaker.wave.1")
            }
        } header: {
            Text("Cues")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(grid.isValid
                     ? "The count-in plays before the video starts. \"Say my moves\" reads the next 8-count's note on count 5. \"Fade\" makes the cues quieter each time a loop starts over, until you dance without them."
                     : "Set the tempo first – the cues follow the beat.")
                if let voiceText {
                    Text(voiceText)
                }
            }
        }
        .disabled(!grid.isValid)
    }

    private var voiceText: String? {
        switch voiceStatus {
        case .notLoaded: return nil
        case .loading: return "Preparing the voice…"
        case .ready: return "Spoken counts ready."
        case .unavailable: return "The iPhone voice isn't available – you'll hear ticks instead."
        }
    }

    // MARK: - Sections

    private var sectionsSection: some View {
        Section {
            ForEach(project.sortedSections, id: \.id) { section in
                HStack {
                    Button {
                        editingSection = SectionDraft(section: section)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.name).foregroundStyle(Color.primary)
                            Text(section.rangeText).font(.caption).foregroundStyle(Theme.secondaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button {
                        onLoopSection(section)
                        dismiss()
                    } label: {
                        Image(systemName: "repeat")
                            .foregroundStyle(Theme.loopColor)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Loop \(section.name)")
                }
            }
            .onDelete { offsets in
                let sorted = project.sortedSections
                for offset in offsets { modelContext.delete(sorted[offset]) }
                try? modelContext.save()
            }
            Button {
                editingSection = SectionDraft(start: hereStart, end: min(hereStart + 3, max(count - 1, 0)))
            } label: {
                Label("New Section", systemImage: "plus")
            }
            .disabled(count == 0)
        } header: {
            Text("Sections")
        } footer: {
            Text("Name parts of the dance (\"Chorus\", \"Dance break\") to loop or drill them with one tap. You can also long-press an 8-count in the list.")
        }
    }

    private func save(_ draft: SectionDraft) {
        draft.save(to: project, context: modelContext)
    }
}

/// What the section editor works on (a copy, saved on "Save").
struct SectionDraft: Identifiable {
    let id = UUID()
    var sectionID: UUID?
    var name: String
    var start: Int
    var end: Int

    init(start: Int, end: Int) {
        sectionID = nil
        name = ""
        self.start = start
        self.end = max(start, end)
    }

    init(section: PracticeSection) {
        sectionID = section.id
        name = section.name
        start = section.startIndex
        end = section.endIndex
    }

    /// Creates the section, or updates the one it was made from.
    @MainActor
    func save(to project: Project, context: ModelContext) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sectionID, let section = project.sections.first(where: { $0.id == sectionID }) {
            if !trimmed.isEmpty { section.name = trimmed }
            section.startIndex = min(start, end)
            section.endIndex = max(start, end)
        } else {
            let section = PracticeSection(name: trimmed.isEmpty ? "Section \(project.sections.count + 1)" : trimmed,
                                          startIndex: start, endIndex: end)
            context.insert(section)
            section.project = project
        }
        project.updatedAt = .now
        try? context.save()
    }
}

/// Name a section and pick its first and last 8-count.
@MainActor
struct SectionEditorSheet: View {
    @State private var draft: SectionDraft
    /// How many 8-counts the video has.
    let count: Int
    let onSave: (SectionDraft) -> Void

    init(draft: SectionDraft, count: Int, onSave: @escaping (SectionDraft) -> Void) {
        _draft = State(initialValue: draft)
        self.count = count
        self.onSave = onSave
    }

    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool

    private static let suggestions = ["Intro", "Verse", "Pre-chorus", "Chorus", "Bridge", "Dance break", "Ending"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Chorus", text: $draft.name)
                        .focused($nameFocused)
                        .submitLabel(.done)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Self.suggestions, id: \.self) { name in
                                Button(name) { draft.name = name }
                                    .buttonStyle(.bordered)
                                    .tint(draft.name == name ? Theme.accent : nil)
                            }
                        }
                    }
                }
                Section("8-counts") {
                    Picker("From", selection: $draft.start) {
                        ForEach(0..<max(count, 1), id: \.self) { Text("8-count \($0 + 1)").tag($0) }
                    }
                    Picker("To", selection: $draft.end) {
                        ForEach(0..<max(count, 1), id: \.self) { Text("8-count \($0 + 1)").tag($0) }
                    }
                }
            }
            .onChange(of: draft.start) { _, start in
                if draft.end < start { draft.end = start }
            }
            .onChange(of: draft.end) { _, end in
                if draft.start > end { draft.start = end }
            }
            .navigationTitle(draft.sectionID == nil ? "New Section" : "Edit Section")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(draft)
                        dismiss()
                    }
                }
            }
            .onAppear { if draft.sectionID == nil { nameFocused = true } }
        }
        .presentationDetents([.medium, .large])
    }
}
