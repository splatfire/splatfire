import SwiftUI
import SwiftData

/// Where everyone stands in one 8-count, seen from the audience (the front
/// of the stage is at the bottom). Stored as JSON in `CountNote.formationData`.
struct Formation: Codable, Equatable {
    struct Dancer: Codable, Equatable, Identifiable {
        var id = UUID()
        var name: String
        /// 0 = stage left edge … 1 = right edge (as the audience sees it).
        var x: Double
        /// 0 = back of the stage … 1 = front.
        var y: Double
        var colorIndex: Int
        /// Your own spot (drawn bigger and highlighted).
        var isMe = false
    }

    var dancers: [Dancer] = []

    static let colors: [Color] = [
        Color(red: 1.0, green: 0.30, blue: 0.40), Color(red: 0.35, green: 0.80, blue: 1.0),
        Color(red: 0.35, green: 0.85, blue: 0.50), Color(red: 1.0, green: 0.72, blue: 0.25),
        Color(red: 0.70, green: 0.50, blue: 1.0), Color(red: 1.0, green: 0.55, blue: 0.85),
        Color(red: 0.55, green: 0.90, blue: 0.85), Color(white: 0.85)
    ]

    static func decode(_ data: Data?) -> Formation? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(Formation.self, from: data)
    }

    func encoded() -> Data? {
        dancers.isEmpty ? nil : try? JSONEncoder().encode(self)
    }

    /// The formation of 8-count `index`, or the closest earlier one (people
    /// stay where they are until the next change).
    @MainActor
    static func effective(for index: Int, in project: Project) -> (formation: Formation, from: Int)? {
        let candidates = project.notes
            .filter { $0.countIndex <= index && $0.formationData != nil }
            .sorted { $0.countIndex > $1.countIndex }
        for note in candidates {
            if let formation = decode(note.formationData), !formation.dancers.isEmpty {
                return (formation, note.countIndex)
            }
        }
        return nil
    }
}

/// A small read-only picture of a formation (in the list and on the video).
struct FormationMiniMap: View {
    let formation: Formation

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.55))
                Rectangle()
                    .fill(Color.white.opacity(0.35))
                    .frame(height: 2)
                    .position(x: size.width / 2, y: size.height - 2)
                ForEach(formation.dancers) { dancer in
                    let dot: CGFloat = dancer.isMe ? 9 : 6
                    let point = Self.point(dancer, in: size, inset: 5)
                    Circle()
                        .fill(Formation.colors[dancer.colorIndex % Formation.colors.count])
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: dancer.isMe ? 1.5 : 0))
                        .frame(width: dot, height: dot)
                        .position(point)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Formation with \(formation.dancers.count) dancers")
    }

    /// Stage position (0…1) → point in a view of `size`, `inset` from the edges.
    static func point(_ dancer: Formation.Dancer, in size: CGSize, inset: CGFloat) -> CGPoint {
        let width: CGFloat = max(size.width - 2 * inset, 1)
        let height: CGFloat = max(size.height - 2 * inset, 1)
        return CGPoint(x: inset + CGFloat(dancer.x) * width, y: inset + CGFloat(dancer.y) * height)
    }
}

/// Draw where everyone stands: drag the dots, tap one to rename it or mark
/// it as you. ‹ › walks through the 8-counts; a new 8-count starts from the
/// previous formation, so you only move the people who change places.
@MainActor
struct FormationEditorSheet: View {
    let project: Project
    /// How many 8-counts there are (for ‹ ›).
    let count: Int

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var index: Int
    @State private var formation = Formation()
    @State private var selectedID: UUID?
    /// Where the formation shown came from when it isn't this 8-count's own.
    @State private var copiedFrom: Int?

    init(project: Project, countIndex: Int, count: Int) {
        self.project = project
        self.count = count
        _index = State(initialValue: countIndex)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                navigator
                stage
                    .aspectRatio(1.6, contentMode: .fit)
                    .padding(.horizontal, 16)
                if let copiedFrom {
                    Text("Same as 8-count \(copiedFrom + 1). Move someone to change it for this 8-count.")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 16)
                }
                dancerControls
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            .background(Theme.background)
            .navigationTitle("Formation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save()
                        dismiss()
                    }
                }
            }
            .onAppear { load() }
        }
        .presentationDetents([.large])
    }

    // MARK: - Pieces

    private var navigator: some View {
        HStack {
            Button {
                go(to: index - 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.round(size: 40))
            .disabled(index == 0)
            .accessibilityLabel("Previous 8-count")
            Spacer()
            Text("8-count \(index + 1)")
                .font(.headline.monospacedDigit())
            Spacer()
            Button {
                go(to: index + 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.round(size: 40))
            .disabled(index + 1 >= max(count, 1))
            .accessibilityLabel("Next 8-count")
        }
        .padding(.horizontal, 16)
    }

    private var stage: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.surface)
                // A light grid to help spacing.
                Path { path in
                    for i in 1..<4 {
                        let x = size.width * CGFloat(i) / 4
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    for i in 1..<3 {
                        let y = size.height * CGFloat(i) / 3
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                }
                .stroke(Theme.hairline, lineWidth: 1)
                Text("AUDIENCE ▾")
                    .font(.system(.caption2, design: .rounded).weight(.bold))
                    .tracking(1)
                    .foregroundStyle(Theme.secondaryText)
                    .position(x: size.width / 2, y: size.height - 10)
                ForEach($formation.dancers) { $dancer in
                    dancerDot(dancer)
                        .position(FormationMiniMap.point(dancer, in: size, inset: 18))
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { value in
                                    let width: CGFloat = max(size.width - 36, 1)
                                    let height: CGFloat = max(size.height - 36, 1)
                                    let x = Double((value.location.x - 18) / width)
                                    let y = Double((value.location.y - 18) / height)
                                    dancer.x = min(max(x, 0), 1)
                                    dancer.y = min(max(y, 0), 1)
                                    selectedID = dancer.id
                                    copiedFrom = nil
                                }
                        )
                        .onTapGesture { selectedID = dancer.id }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func dancerDot(_ dancer: Formation.Dancer) -> some View {
        let color = Formation.colors[dancer.colorIndex % Formation.colors.count]
        let selected = selectedID == dancer.id
        return VStack(spacing: 2) {
            Text(initials(dancer.name))
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.black)
                .frame(width: dancer.isMe ? 36 : 30, height: dancer.isMe ? 36 : 30)
                .background(Circle().fill(color))
                .overlay(Circle().strokeBorder(Color.white, lineWidth: selected ? 3 : (dancer.isMe ? 2 : 0)))
        }
        .contentShape(Circle())
        .accessibilityLabel("\(dancer.name)\(dancer.isMe ? ", you" : "")")
        .accessibilityHint("Drag to move")
    }

    @ViewBuilder
    private var dancerControls: some View {
        VStack(spacing: 10) {
            if let i = formation.dancers.firstIndex(where: { $0.id == selectedID }) {
                HStack(spacing: 10) {
                    TextField("Name", text: $formation.dancers[i].name)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Me", isOn: Binding(
                        get: { formation.dancers[i].isMe },
                        set: { on in
                            for j in formation.dancers.indices { formation.dancers[j].isMe = false }
                            formation.dancers[i].isMe = on
                            copiedFrom = nil
                        }
                    ))
                    .fixedSize()
                    Button(role: .destructive) {
                        formation.dancers.remove(at: i)
                        selectedID = nil
                        copiedFrom = nil
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.round(size: 40))
                    .accessibilityLabel("Remove dancer")
                }
            }
            HStack(spacing: 10) {
                Button {
                    addDancer()
                } label: {
                    Label("Add dancer", systemImage: "person.badge.plus")
                }
                .buttonStyle(.big(isOn: true))
                if !formation.dancers.isEmpty {
                    Button(role: .destructive) {
                        formation.dancers.removeAll()
                        selectedID = nil
                        copiedFrom = nil
                    } label: {
                        Label("Clear", systemImage: "xmark")
                    }
                    .buttonStyle(.big)
                }
            }
            Text("Drag the dots to where everyone stands. Tap one to name it or mark it as you.")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Data

    private func initials(_ name: String) -> String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    private func addDancer() {
        let n = formation.dancers.count
        // New people start in a row across the middle.
        let x = 0.15 + 0.7 * Double(n % 5) / 4
        let y = 0.35 + 0.25 * Double((n / 5) % 3)
        let dancer = Formation.Dancer(name: "Dancer \(n + 1)", x: x, y: y, colorIndex: n % Formation.colors.count,
                                      isMe: n == 0)
        formation.dancers.append(dancer)
        selectedID = dancer.id
        copiedFrom = nil
    }

    private func load() {
        selectedID = nil
        if let own = Formation.decode(project.note(for: index)?.formationData), !own.dancers.isEmpty {
            formation = own
            copiedFrom = nil
        } else if let earlier = Formation.effective(for: index, in: project) {
            formation = earlier.formation
            copiedFrom = earlier.from
        } else {
            formation = Formation()
            copiedFrom = nil
        }
    }

    /// Saves this 8-count's own formation (only if it was changed here).
    private func save() {
        guard copiedFrom == nil else { return }
        let data = formation.encoded()
        let existing = project.note(for: index)
        guard data != nil || existing?.formationData != nil else { return }
        let note = NoteStore.note(for: index, in: project, context: modelContext)
        note.formationData = data
        note.updatedAt = .now
        project.updatedAt = .now
        try? modelContext.save()
        if data == nil { NoteStore.deleteIfEmpty(note, context: modelContext) }
    }

    private func go(to newIndex: Int) {
        guard newIndex >= 0, newIndex < max(count, 1) else { return }
        save()
        index = newIndex
        load()
    }
}
