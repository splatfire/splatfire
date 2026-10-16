import SwiftUI

// Liquid Glass support.
//
// Liquid Glass is Apple's design from iOS 26 on (refined in iOS 27). When
// you build with Xcode 26 or newer, system parts (navigation bars, toolbars,
// sheets, menus) get it automatically. Our own big buttons opt in here.
//
// Two guards keep the app working everywhere:
//  - `#if compiler(>=6.2)`: only compile the glass code with Xcode 26+
//    (older Xcode doesn't know `glassEffect`).
//  - `if #available(iOS 26.0, *)`: only use it on iPhones running iOS 26+;
//    iOS 17–25 get the solid look.

extension Theme {
    /// True when Liquid Glass is available (built with Xcode 26+, running iOS 26+).
    static var usesGlass: Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }
}

extension View {
    /// Liquid Glass in `shape` on iOS 26+, otherwise a solid fill.
    /// - Parameters:
    ///   - tint: colors the glass (e.g. the accent for "on" buttons).
    ///   - interactive: glass reacts to touches (for buttons).
    ///   - fallback: fill color used before iOS 26 when there's no tint.
    @ViewBuilder
    func glassSurface<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false,
                                fallback: Color = Theme.surfaceRaised) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            self.background(shape.fill(tint ?? fallback))
        }
        #else
        self.background(shape.fill(tint ?? fallback))
        #endif
    }
}

/// Groups several glass controls so iOS 26+ renders them together (they can
/// blend into each other smoothly). Before iOS 26 it just shows the content.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}
