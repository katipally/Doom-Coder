import SwiftUI

// MARK: - DoomCoder iOS Liquid Glass card
//
// iOS-side mirror of `DoomCoder/GlassCard.swift` (mac side). Two copies
// because they live in different targets and the SwiftPM module
// `DoomCoderCore` doesn't import SwiftUI. If a third target is added,
// promote this to the package.
//
// Usage:
//   .doomGlassCard()                  // default corner radius 14
//   .doomGlassCard(tint: .orange)     // tinted (status pill etc.)
//   .doomGlassPill(tint: .orange)     // capsule variant for badges

struct GlassCardBackground: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Color

    init(cornerRadius: CGFloat = 14, tint: Color = .clear) {
        self.cornerRadius = cornerRadius
        self.tint = tint
    }

    func body(content: Content) -> some View {
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
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
    }
}

struct GlassPillBackground: ViewModifier {
    var tint: Color
    init(tint: Color = .clear) { self.tint = tint }
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                Capsule()
                    .fill(tint.opacity(0.18))
            }
            .background {
                if #available(iOS 26.0, *) {
                    Capsule()
                        .fill(.clear)
                        .glassEffect(.regular.interactive(false), in: Capsule())
                } else {
                    Capsule().fill(.regularMaterial)
                }
            }
            .overlay(
                Capsule().strokeBorder(tint.opacity(0.28), lineWidth: 0.5)
            )
    }
}

private extension View {
    @ViewBuilder
    func glassEffectIfAvailable() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(true), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            self.background(.regularMaterial)
        }
    }
}

extension View {
    /// Applies the canonical DoomCoder Liquid Glass card chrome (iOS).
    func doomGlassCard(cornerRadius: CGFloat = 14) -> some View {
        modifier(GlassCardBackground(cornerRadius: cornerRadius, tint: .clear))
    }

    /// Tinted glass card (e.g. snooze, warning).
    func doomGlassCard(tint: Color, cornerRadius: CGFloat = 12) -> some View {
        modifier(GlassCardBackground(cornerRadius: cornerRadius, tint: tint))
    }

    /// Applies a glass capsule background.
    func doomGlassPill(tint: Color = .clear) -> some View {
        modifier(GlassPillBackground(tint: tint))
    }
}
