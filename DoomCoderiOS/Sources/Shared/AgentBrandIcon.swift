import SwiftUI

// MARK: - Brand color palette (hex → Color)

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8)  & 0xFF) / 255
        let b = Double( hex        & 0xFF) / 255
        self.init(red: r, green: g, blue: b, opacity: opacity)
    }
}

enum AgentBrand: CaseIterable {
    case claude, cursor, vscode, copilotCLI, windsurf, codexCLI, unknown

    init(rawAgent: String) {
        switch rawAgent.lowercased() {
        case "claude":      self = .claude
        case "cursor":      self = .cursor
        case "vscode":      self = .vscode
        case "copilot_cli": self = .copilotCLI
        case "windsurf":    self = .windsurf
        case "codex_cli":   self = .codexCLI
        default:            self = .unknown
        }
    }

    // MARK: - Colors (single canonical source — do not define agent colors elsewhere)

    var primaryColor: Color { Color(hex: colorHex) }

    var colorHex: UInt32 {
        switch self {
        case .claude:     return 0xE06B37
        case .cursor:     return 0x6B46C1
        case .vscode:     return 0x5A7FA6
        case .copilotCLI: return 0x2088FF
        case .windsurf:   return 0x0FBBDD
        case .codexCLI:   return 0x22C55E
        case .unknown:    return 0x888888
        }
    }

    /// Hex string for use in ActivityKit attributes (e.g. "#E06B37")
    var colorHexString: String { String(format: "#%06X", colorHex) }

    // MARK: - Names

    /// Short name used in compact contexts (Dynamic Island compact, notifications)
    var displayName: String {
        switch self {
        case .claude:     return "Claude"
        case .cursor:     return "Cursor"
        case .vscode:     return "VS Code"
        case .copilotCLI: return "Copilot"
        case .windsurf:   return "Windsurf"
        case .codexCLI:   return "Codex"
        case .unknown:    return "Agent"
        }
    }

    /// Full product name used in session cards and history
    var fullDisplayName: String {
        switch self {
        case .claude:     return "Claude Code"
        case .cursor:     return "Cursor"
        case .vscode:     return "VS Code Copilot"
        case .copilotCLI: return "GitHub Copilot"
        case .windsurf:   return "Windsurf"
        case .codexCLI:   return "Codex CLI"
        case .unknown:    return "Unknown Agent"
        }
    }

    // MARK: - Icons

    /// Asset catalog name for the bundled brand PNG (640×640 shipped with app)
    var iconAssetName: String {
        switch self {
        case .claude:     return "agent-claude"
        case .cursor:     return "agent-cursor"
        case .vscode:     return "agent-vscode"
        case .copilotCLI: return "agent-copilot"
        case .windsurf:   return "agent-windsurf"
        case .codexCLI:   return "agent-codex"
        case .unknown:    return ""
        }
    }

    var sfSymbolName: String {
        switch self {
        case .claude:     return "c.circle.fill"
        case .cursor:     return "cursorarrow.rays"
        case .vscode:     return "chevron.left.forwardslash.chevron.right"
        case .copilotCLI: return "terminal.fill"
        case .windsurf:   return "wind"
        case .codexCLI:   return "sparkles.rectangle.stack"
        case .unknown:    return "cpu.fill"
        }
    }

    /// Renders the bundled brand PNG as a UIImage. Falls back to nil if asset missing.
    func toUIImage(size: CGFloat = 64) -> UIImage? {
        guard !iconAssetName.isEmpty else { return nil }
        return UIImage(named: iconAssetName)
    }

    /// The canonical hook-layer agent name (matches what dc-hook sends and icon file names use).
    var agentKey: String {
        switch self {
        case .claude:     return "claude"
        case .cursor:     return "cursor"
        case .vscode:     return "vscode"
        case .copilotCLI: return "copilot_cli"
        case .windsurf:   return "windsurf"
        case .codexCLI:   return "codex_cli"
        case .unknown:    return "unknown"
        }
    }

    var initial: String { String(displayName.prefix(1)) }

    // MARK: - Convenience

    static var allKnown: [AgentBrand] {
        [.claude, .cursor, .vscode, .copilotCLI, .windsurf, .codexCLI]
    }
}

// MARK: - AgentBrandIcon

/// A SwiftUI view that renders a brand-representative icon for an AI coding agent.
/// Uses `Canvas`/`Path` drawing — no UIKit, no `Image(named:)`. Safe for use in
/// the iOS app. For the widget extension, use `AgentBrandIconShape` (inline below).
struct AgentBrandIcon: View {
    let agent: String
    let size: CGFloat

    private var brand: AgentBrand { AgentBrand(rawAgent: agent) }
    private var color: Color { brand.primaryColor }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(color.opacity(0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                        .strokeBorder(color.opacity(0.35), lineWidth: 1)
                )

            Group {
                switch brand {
                case .claude:     ClaudeLogoMark(color: color, size: size * 0.58)
                case .cursor:     CursorLogoMark(color: color, size: size * 0.58)
                case .vscode:     VSCodeLogoMark(color: color, size: size * 0.58)
                case .copilotCLI: CopilotLogoMark(color: color, size: size * 0.58)
                case .windsurf:   WindsurfLogoMark(color: color, size: size * 0.58)
                case .codexCLI:   CodexLogoMark(color: color, size: size * 0.58)
                case .unknown:    UnknownLogoMark(color: color, size: size * 0.58)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Logo marks

/// Claude: Anthropic's asterisk — 6 radiating bars from center
private struct ClaudeLogoMark: View {
    let color: Color
    let size: CGFloat
    var body: some View {
        Canvas { ctx, sz in
            let cx = sz.width / 2, cy = sz.height / 2
            let barLen = sz.width * 0.44
            let barW   = sz.width * 0.13
            for i in 0..<6 {
                let angle = Double(i) * .pi / 3
                var env = ctx
                env.translateBy(x: cx, y: cy)
                env.rotate(by: .radians(angle))
                let r = Path(roundedRect: CGRect(x: -barW / 2, y: sz.height * 0.08,
                                                 width: barW, height: barLen),
                             cornerRadius: barW / 2)
                env.fill(r, with: .color(color))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Cursor: diagonal arrow (the Cursor IDE cursor shape)
private struct CursorLogoMark: View {
    let color: Color
    let size: CGFloat
    var body: some View {
        Canvas { ctx, sz in
            let s = sz.width
            var path = Path()
            // Arrow tip at top-left, pointing down-right
            path.move(to: CGPoint(x: s * 0.15, y: s * 0.10))
            path.addLine(to: CGPoint(x: s * 0.15, y: s * 0.80))
            path.addLine(to: CGPoint(x: s * 0.37, y: s * 0.59))
            path.addLine(to: CGPoint(x: s * 0.55, y: s * 0.90))
            path.addLine(to: CGPoint(x: s * 0.66, y: s * 0.84))
            path.addLine(to: CGPoint(x: s * 0.48, y: s * 0.54))
            path.addLine(to: CGPoint(x: s * 0.75, y: s * 0.54))
            path.closeSubpath()
            ctx.fill(path, with: .color(color))
        }
        .frame(width: size, height: size)
    }
}

/// VS Code: `</>` in monospaced font
private struct VSCodeLogoMark: View {
    let color: Color
    let size: CGFloat
    var body: some View {
        Text("</>")
            .font(.system(size: size * 0.36, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: size, height: size)
    }
}

/// Copilot: stylised goggles — arc + two eye circles
private struct CopilotLogoMark: View {
    let color: Color
    let size: CGFloat
    var body: some View {
        Canvas { ctx, sz in
            let s  = sz.width
            let lw = s * 0.11
            // Outer headband arc
            var arc = Path()
            arc.addArc(center: CGPoint(x: s / 2, y: s * 0.56),
                       radius: s * 0.36, startAngle: .degrees(180), endAngle: .degrees(0),
                       clockwise: false)
            ctx.stroke(arc, with: .color(color), lineWidth: lw)
            // Left eye
            ctx.stroke(Path(ellipseIn: CGRect(x: s * 0.10, y: s * 0.45, width: s * 0.30, height: s * 0.30)),
                       with: .color(color), lineWidth: lw)
            // Right eye
            ctx.stroke(Path(ellipseIn: CGRect(x: s * 0.60, y: s * 0.45, width: s * 0.30, height: s * 0.30)),
                       with: .color(color), lineWidth: lw)
        }
        .frame(width: size, height: size)
    }
}

/// Windsurf: two stacked wave curves
private struct WindsurfLogoMark: View {
    let color: Color
    let size: CGFloat
    var body: some View {
        Canvas { ctx, sz in
            let s  = sz.width
            let lw = s * 0.10
            for offset: CGFloat in [0, s * 0.22] {
                var wave = Path()
                wave.move(to: CGPoint(x: s * 0.05, y: s * 0.38 + offset))
                wave.addCurve(to:      CGPoint(x: s * 0.50, y: s * 0.38 + offset),
                              control1: CGPoint(x: s * 0.20, y: s * 0.22 + offset),
                              control2: CGPoint(x: s * 0.35, y: s * 0.54 + offset))
                wave.addCurve(to:      CGPoint(x: s * 0.95, y: s * 0.38 + offset),
                              control1: CGPoint(x: s * 0.65, y: s * 0.22 + offset),
                              control2: CGPoint(x: s * 0.80, y: s * 0.54 + offset))
                ctx.stroke(wave, with: .color(color), lineWidth: lw)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Codex CLI: `>_` terminal prompt
private struct CodexLogoMark: View {
    let color: Color
    let size: CGFloat
    var body: some View {
        Text(">_")
            .font(.system(size: size * 0.38, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: size, height: size)
    }
}

/// Fallback: simple initial letter
private struct UnknownLogoMark: View {
    let color: Color
    let size: CGFloat
    var body: some View {
        Image(systemName: "cpu.fill")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
    }
}

// MARK: - Preview

#Preview {
    HStack(spacing: 12) {
        ForEach(["claude", "cursor", "vscode", "copilot_cli", "windsurf", "codex_cli"], id: \.self) { agent in
            VStack(spacing: 4) {
                AgentBrandIcon(agent: agent, size: 44)
                Text(AgentBrand(rawAgent: agent).displayName)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }
    .padding()
    .background(.black)
}
