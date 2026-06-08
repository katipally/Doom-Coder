import SwiftUI

// MARK: - RainbowIdleGlow
//
// Apple Intelligence-style rotating rainbow aurora rendered on the
// input bar border when the bar is idle (empty + unfocused). Purely
// decorative — no interaction. Respects the system Reduce Motion
// accessibility setting.
//
// Shared between the Mac floating panel / Prompts / Notes panes
// (`ToolsWindow.swift`) and the iOS Prompts view
// (`DoomCoderCompanion/.../PromptsView.swift`). The two copies are
// identical; the only reason for two is that they live in different
// targets. Any change should be applied to both.

public struct RainbowIdleGlow: View {
    public let cornerRadius: CGFloat
    @State private var angle: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
    }

    // Apple Intelligence aurora palette — purple → blue → cyan → teal →
    // green → yellow → orange → pink → purple (loops cleanly).
    private let colors: [Color] = [
        Color(hue: 0.75, saturation: 0.90, brightness: 1.0),
        Color(hue: 0.63, saturation: 0.90, brightness: 1.0),
        Color(hue: 0.53, saturation: 0.90, brightness: 1.0),
        Color(hue: 0.46, saturation: 0.80, brightness: 1.0),
        Color(hue: 0.36, saturation: 0.85, brightness: 1.0),
        Color(hue: 0.15, saturation: 0.95, brightness: 1.0),
        Color(hue: 0.08, saturation: 0.95, brightness: 1.0),
        Color(hue: 0.95, saturation: 0.90, brightness: 1.0),
        Color(hue: 0.75, saturation: 0.90, brightness: 1.0),
    ]

    public var body: some View {
        let gradient = AngularGradient(
            colors: colors, center: .center, angle: .degrees(angle)
        )
        ZStack {
            // Soft outer bloom
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(gradient, lineWidth: 5)
                .blur(radius: 9)
                .opacity(0.65)
            // Crisp inner ring
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(gradient, lineWidth: 1.5)
                .opacity(0.9)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 4.5).repeatForever(autoreverses: false)) {
                angle = 360
            }
        }
    }
}
