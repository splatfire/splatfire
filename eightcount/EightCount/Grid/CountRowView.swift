import SwiftUI
import SwiftData

/// One 8-count in the list: number, start time, notes preview, little
/// detail chips, snapshot thumbnails, plus Loop and Edit buttons.
@MainActor
struct CountRowView: View {
    /// 0-based index (shown as index + 1).
    let index: Int
    /// Video time (seconds) where this 8-count starts.
    let startTime: Double
    /// The note for this 8-count, if one exists.
    let note: CountNote?
    /// True while the video is playing inside this 8-count.
    let isCurrent: Bool
    /// True while this 8-count is being looped.
    let isLooped: Bool
    /// How well you know it (shown under the number).
    let mastery: Mastery
    let onJump: () -> Void
    let onToggleLoop: () -> Void
    let onEdit: () -> Void

    /// How many thumbnails fit in the row before we show "+n".
    private static let maxThumbnails = 4

    init(index: Int, startTime: Double, note: CountNote?, isCurrent: Bool, isLooped: Bool,
         mastery: Mastery = .unmarked,
         onJump: @escaping () -> Void,
         onToggleLoop: @escaping () -> Void,
         onEdit: @escaping () -> Void) {
        self.index = index
        self.startTime = startTime
        self.note = note
        self.isCurrent = isCurrent
        self.isLooped = isLooped
        self.mastery = mastery
        self.onJump = onJump
        self.onToggleLoop = onToggleLoop
        self.onEdit = onEdit
    }

    /// Size of the round loop / edit buttons (side by side, so rows stay compact).
    private static let buttonSize: CGFloat = 44

    var body: some View {
        HStack(alignment: .center, spacing: Theme.spacingS) {
            // The whole left part is one big button: tap = jump here.
            Button(action: onJump) {
                HStack(alignment: .top, spacing: Theme.spacingM) {
                    numberColumn
                    details
                }
                .frame(maxWidth: .infinity, minHeight: Self.buttonSize, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Jumps the video to this 8-count")

            // Separate buttons, so they never trigger the jump.
            HStack(spacing: Theme.spacingS) {
                loopButton
                editButton
            }
        }
        .card(padding: 10, highlighted: isCurrent)
        .overlay(
            // A quiet outline marks the looped 8-count (the current one has its own highlight).
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .strokeBorder(Theme.loopColor.opacity(0.45), lineWidth: 1)
                .opacity(isLooped && !isCurrent ? 1 : 0)
        )
        .animation(.easeInOut(duration: 0.2), value: isCurrent)
        .animation(.easeInOut(duration: 0.2), value: isLooped)
    }

    // MARK: - Left side

    private var numberColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(index + 1)")
                .font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
                .foregroundStyle(isCurrent ? Theme.accent : Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(formatTime(startTime))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if mastery != .unmarked {
                Image(systemName: mastery.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(mastery == .known ? Theme.known : Theme.learning)
                    .padding(.top, 2)
            }
        }
        .frame(width: 52, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("8-count \(index + 1), starts at \(formatTime(startTime))"
                            + (mastery == .unmarked ? "" : ", \(mastery.title)"))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            let mainText = (note?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if mainText.isEmpty {
                Text("Add moves…")
                    .font(.subheadline.italic())
                    .foregroundStyle(Theme.secondaryText)
            } else {
                Text(mainText)
                    .font(.subheadline)
                    .foregroundStyle(Color.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            let chips = makeChips()
            if !chips.isEmpty {
                ChipFlowLayout(spacing: 6) {
                    ForEach(chips) { chip in
                        chipView(chip)
                    }
                }
            }

            if let note, !note.snapshots.isEmpty {
                thumbnailStrip(note.sortedSnapshots)
            }

            if let formation = Formation.decode(note?.formationData), !formation.dancers.isEmpty {
                FormationMiniMap(formation: formation)
                    .frame(width: 72, height: 45)
            }
        }
        .padding(.top, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Chips (feet / arms / facing / lyric)

    private struct Chip: Identifiable {
        let id: String
        let icon: String
        let text: String
        var isLyric = false
    }

    private func makeChips() -> [Chip] {
        guard let note else { return [] }
        func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        var chips: [Chip] = []
        let feet = clean(note.feet)
        let arms = clean(note.arms)
        let facing = clean(note.facing)
        let lyric = clean(note.lyric)
        if !feet.isEmpty { chips.append(Chip(id: "feet", icon: "shoeprints.fill", text: feet)) }
        if !arms.isEmpty { chips.append(Chip(id: "arms", icon: "figure.arms.open", text: arms)) }
        if !facing.isEmpty { chips.append(Chip(id: "facing", icon: "location.north.line.fill", text: facing)) }
        if !lyric.isEmpty { chips.append(Chip(id: "lyric", icon: "music.note", text: "“\(lyric)”", isLyric: true)) }
        return chips
    }

    private func chipView(_ chip: Chip) -> some View {
        HStack(spacing: 4) {
            Image(systemName: chip.icon)
                .font(.caption2)
                .foregroundStyle(chip.isLyric ? Theme.loopColor : Theme.secondaryText)
            Text(chip.text)
                .font(.caption)
                .italic(chip.isLyric)
                .lineLimit(1)
        }
        .foregroundStyle(Color.white.opacity(0.88))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Theme.surfaceRaised))
    }

    // MARK: - Snapshot thumbnails

    private func thumbnailStrip(_ snapshots: [PoseSnapshot]) -> some View {
        let shown = Array(snapshots.prefix(Self.maxThumbnails))
        let extra = snapshots.count - shown.count
        return HStack(spacing: 6) {
            ForEach(shown) { snapshot in
                SnapshotThumbnailView(snapshot: snapshot, width: 40, height: 52)
            }
            if extra > 0 {
                Text("+\(extra)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 40, height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.surfaceRaised)
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(snapshots.count) snapshot\(snapshots.count == 1 ? "" : "s")")
    }

    // MARK: - Right side buttons

    private var loopButton: some View {
        Button(action: onToggleLoop) {
            Image(systemName: "repeat")
        }
        .buttonStyle(.round(size: Self.buttonSize, isOn: isLooped, tint: Theme.loopColor))
        .accessibilityLabel(loopButtonLabel)
    }

    private var loopButtonLabel: String {
        isLooped ? "Stop looping 8-count \(index + 1)" : "Loop 8-count \(index + 1)"
    }

    private var editButton: some View {
        Button(action: onEdit) {
            Image(systemName: "pencil")
        }
        .buttonStyle(.round(size: Self.buttonSize))
        .accessibilityLabel("Edit notes for 8-count \(index + 1)")
    }
}

/// Lays chips out left to right and wraps to a new line when full.
private struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            let size = fittedSize(of: subview, maxWidth: maxWidth)
            if x > 0 && x + size.width > maxWidth {
                // Next line.
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width
            widest = max(widest, x)
            x += spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = fittedSize(of: subview, maxWidth: bounds.width)
            if x > 0 && x + size.width > bounds.width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(width: size.width, height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    /// The chip's natural size, but never wider than the row.
    private func fittedSize(of subview: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard ideal.width > maxWidth, maxWidth.isFinite else { return ideal }
        return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }
}
