import SwiftUI

/// Colors and reusable styles so the whole app looks consistent.
enum Theme {
    static let accent = Color(red: 1.0, green: 0.30, blue: 0.40)     // coral pink
    static let background = Color.black
    static let surface = Color(white: 0.11)                           // cards, rows
    static let surfaceRaised = Color(white: 0.17)                     // buttons
    static let highlight = Color(red: 1.0, green: 0.30, blue: 0.40).opacity(0.22)
    static let loopColor = Color(red: 0.35, green: 0.80, blue: 1.0)   // A-B / loop
    static let secondaryText = Color(white: 0.62)
    /// Progress marks: "Got it" and "Still learning".
    static let known = Color(red: 0.35, green: 0.85, blue: 0.50)
    static let learning = Color(red: 1.0, green: 0.72, blue: 0.25)

    /// Minimum height for tappable controls. Apple recommends 44 pt; we go
    /// bigger because the phone is often on a stand away from you.
    static let tapHeight: CGFloat = 52
}

/// A big rounded button used for most controls.
/// `isOn` tints the button to show an active toggle (mirror, loop, ...).
/// On iOS 26+ it is made of Liquid Glass (see Design/Glass.swift).
struct BigButtonStyle: ButtonStyle {
    var isOn = false
    var tint: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        let glass = Theme.usesGlass
        configuration.label
            .font(.system(.headline, design: .rounded))
            .frame(maxWidth: .infinity, minHeight: Theme.tapHeight)
            .padding(.horizontal, 6)
            // Tinted glass is see-through, so white text reads better there.
            .foregroundStyle(isOn && !glass ? Color.black : Color.white)
            .glassSurface(
                RoundedRectangle(cornerRadius: 14, style: .continuous),
                tint: isOn ? tint : nil,
                interactive: true
            )
            .opacity(configuration.isPressed && !glass ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == BigButtonStyle {
    static var big: BigButtonStyle { BigButtonStyle() }
    static func big(isOn: Bool, tint: Color = Theme.accent) -> BigButtonStyle {
        BigButtonStyle(isOn: isOn, tint: tint)
    }
}

/// Formats seconds as "1:05.32" (minutes:seconds.hundredths).
func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "--:--" }
    let sign = seconds < 0 ? "-" : ""
    let total = abs(seconds)
    let minutes = Int(total) / 60
    let secs = total - Double(minutes * 60)
    return sign + String(format: "%d:%05.2f", minutes, secs)
}
