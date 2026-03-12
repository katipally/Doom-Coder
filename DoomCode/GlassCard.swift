import SwiftUI
import DoomCodeCore

// MARK: - DoomCode Liquid Glass card
//
// A single source of truth for the macOS 26 / iOS 26 "Liquid Glass" surface
// used across both apps. Wraps `RoundedRectangle` with a `glassEffect(.regular)`
// fill and a 0.5pt hairline border, falling back to a system material on
// older OSes.
//
// Usage:
//   .doomGlassCard()                          // default corner radius 14
//   .doomGlassCard(cornerRadius: 16)          // larger cards (panels)
//   .doomGlassCard(tint: .orange)             // tinted card
//
// The intent is a tactile, glassy card that lets the desktop / app
// background show through subtly. Use sparingly — every glass surface adds
// cost. For large container surfaces (full panel, full window) prefer a
// `Color.clear` + `.glassEffect` on the whole container.

public struct GlassCardBackground: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Color

    public init(cornerRadius: CGFloat = 14, tint: Color = .clear) {
        self.cornerRadius = cornerRadius
        self.tint = tint
    }

    public func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tint)
            }
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.clear)
                    .glassEffectIfAvailable()
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5)
            )
    }
}

private extension View {
    @ViewBuilder
    func glassEffectIfAvailable() -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            self.glassEffect(.regular.interactive(true), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            // Older OS fallback: a thin system material. Slightly less
            // frosted but readable.
            self.background(.thinMaterial)
        }
    }
}

public extension View {
    /// Applies the canonical DoomCode Liquid Glass card chrome.
    func doomGlassCard(cornerRadius: CGFloat = 14) -> some View {
        modifier(GlassCardBackground(cornerRadius: cornerRadius, tint: .clear))
    }

    /// Tinted glass card (e.g. snooze, warning). Uses a low-opacity color
    /// overlay on top of the standard glass effect.
    func doomGlassCard(tint: Color, cornerRadius: CGFloat = 12) -> some View {
        modifier(GlassCardBackground(cornerRadius: cornerRadius, tint: tint))
    }
}
