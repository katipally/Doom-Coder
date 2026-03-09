import SwiftUI

// MARK: - Glass button styles
//
// Thin wrappers around Apple's iOS 26 / macOS 26 Liquid Glass button styles
// (`GlassButtonStyle` and `GlassProminentButtonStyle`) so call sites read
// as intent rather than framework jargon. We don't redefine the styles
// — we expose semantic accessors.
//
// Usage:
//   .buttonStyle(.doomGlass)          // subtle frosted button
//   .buttonStyle(.doomGlassProminent) // filled glass, primary action

public extension PrimitiveButtonStyle where Self == SwiftUI.GlassButtonStyle {
    static var doomGlass: SwiftUI.GlassButtonStyle { .glass }
}

public extension PrimitiveButtonStyle where Self == SwiftUI.GlassProminentButtonStyle {
    static var doomGlassProminent: SwiftUI.GlassProminentButtonStyle { .glassProminent }
}

// MARK: - Capsule glass label
//
// A small "pill" badge that uses Liquid Glass. Used for status indicators,
// counts, and tiny inline labels. Falls back to a flat material on older
// OSes.

public struct GlassPill: ViewModifier {
    var tint: Color

    public init(tint: Color = .clear) { self.tint = tint }

    public func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                Capsule()
                    .fill(tint.opacity(0.18))
            }
            .background {
                if #available(macOS 26.0, iOS 26.0, *) {
                    Capsule()
                        .fill(.clear)
                        .glassEffect(.regular.interactive(false), in: Capsule())
                } else {
                    Capsule().fill(.thinMaterial)
                }
            }
            .overlay(
                Capsule().strokeBorder(tint.opacity(0.28), lineWidth: 0.5)
            )
    }
}

public extension View {
    /// Applies a glass capsule background — the standard "status pill"
    /// look used across the floating panel, Configure, and iOS app.
    func doomGlassPill(tint: Color = .clear) -> some View {
        modifier(GlassPill(tint: tint))
    }
}
