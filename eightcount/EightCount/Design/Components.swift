import SwiftUI

// Small, reusable building blocks for a calm, consistent look.
// Rules of thumb used across the app:
//  - One accent-colored thing per area (the Play button, the current row).
//  - Icons instead of text where the meaning is obvious.
//  - Round buttons for actions, capsules for choices, cards for content.

extension Theme {
    /// Standard spacing steps.
    static let spacingS: CGFloat = 8
    static let spacingM: CGFloat = 12
    static let spacingL: CGFloat = 20
    /// Corner radius of cards and the video.
    static let cardCorner: CGFloat = 18
    /// Height of compact controls (still a comfortable 44 pt tap target).
    static let controlHeight: CGFloat = 44
    /// Hairline separators.
    static let hairline = Color.white.opacity(0.08)
}

// MARK: - Round icon button

/// A circular button with an SF Symbol, e.g. "gobackward.5".
/// - `prominent`: solid accent fill (use for the one main action, like Play).
/// - `isOn`: tinted to show an active toggle (mirror, loop).
struct RoundIconButtonStyle: ButtonStyle {
    var size: CGFloat = 48
    var prominent = false
    var isOn = false
    var tint: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * (prominent ? 0.36 : 0.38), weight: .semibold))
            .frame(width: size, height: size)
            .foregroundStyle(foreground)
            .background {
                if prominent {
                    Circle().fill(tint)
                }
            }
            .modifier(RoundGlassIfNeeded(prominent: prominent, isOn: isOn, tint: tint))
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(Circle())
    }

    private var foreground: Color {
        if prominent { return .black }
        if isOn { return Theme.usesGlass ? .white : .black }
        return .white
    }
}

/// Glass (or a solid fallback) behind non-prominent round buttons.
private struct RoundGlassIfNeeded: ViewModifier {
    let prominent: Bool
    let isOn: Bool
    let tint: Color

    func body(content: Content) -> some View {
        if prominent {
            content
        } else {
            content.glassSurface(Circle(), tint: isOn ? tint : nil, interactive: true)
        }
    }
}

extension ButtonStyle where Self == RoundIconButtonStyle {
    static func round(size: CGFloat = 48, prominent: Bool = false, isOn: Bool = false,
                      tint: Color = Theme.accent) -> RoundIconButtonStyle {
        RoundIconButtonStyle(size: size, prominent: prominent, isOn: isOn, tint: tint)
    }
}

// MARK: - Pill segmented control

/// A capsule with several choices, the selected one highlighted
/// (e.g. playback speed). Each option has its own accessibility label.
struct PillPicker<Value: Hashable>: View {
    struct Option {
        let value: Value
        let title: String
        let accessibilityLabel: String
    }

    let options: [Option]
    let selection: Value
    var tint: Color = Theme.accent
    let onSelect: (Value) -> Void

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    onSelect(option.value)
                } label: {
                    Text(option.title)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(selected ? Color.black : Color.white.opacity(0.85))
                        .frame(maxWidth: .infinity, minHeight: Theme.controlHeight - 6)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(tint)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.accessibilityLabel)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .frame(height: Theme.controlHeight)
        .glassSurface(Capsule(), fallback: Theme.surface)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selection)
    }
}

// MARK: - Card

extension View {
    /// A rounded content card on the dark background.
    func card(padding: CGFloat = Theme.spacingM, highlighted: Bool = false) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                    .fill(highlighted ? Theme.accent.opacity(0.12) : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                    .strokeBorder(highlighted ? Theme.accent.opacity(0.45) : Theme.hairline, lineWidth: 1)
            )
    }
}
