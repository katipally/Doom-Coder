import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - Color helper

private extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        self.init(
            red:   Double((int & 0xFF0000) >> 16) / 255,
            green: Double((int & 0x00FF00) >> 8)  / 255,
            blue:  Double( int & 0x0000FF)         / 255
        )
    }
}

// MARK: - Agent helpers

private func agentSFSymbol(_ agent: String) -> String {
    switch agent {
    case "claude":      return "c.circle.fill"
    case "cursor":      return "cursorarrow.rays"
    case "vscode":      return "chevron.left.forwardslash.chevron.right"
    case "copilot_cli": return "terminal.fill"
    case "windsurf":    return "wind"
    case "codex_cli":   return "sparkles.rectangle.stack"
    default:            return "cpu.fill"
    }
}

private func agentDisplayName(_ agent: String) -> String {
    switch agent {
    case "claude":      return "Claude"
    case "cursor":      return "Cursor"
    case "vscode":      return "VS Code"
    case "copilot_cli": return "Copilot"
    case "windsurf":    return "Windsurf"
    case "codex_cli":   return "Codex"
    default:            return agent.capitalized
    }
}

// MARK: - Status helpers

private func statusSystemImage(_ status: String) -> String {
    switch status {
    case "running":         return "circle.fill"
    case "waitingApproval": return "exclamationmark.circle.fill"
    case "completed":       return "checkmark.circle.fill"
    case "failed":          return "xmark.circle.fill"
    default:                return "circle"
    }
}

private func statusColor(_ status: String) -> Color {
    switch status {
    case "running":         return .green
    case "waitingApproval": return .orange
    case "failed":          return .red
    default:                return .gray
    }
}

private func formatElapsed(_ sec: Int) -> String {
    let m = sec / 60; let s = sec % 60
    return "\(m):\(String(format: "%02d", s))"
}

// MARK: - Agent icon (inline Canvas — widget target cannot import app sources)

private func agentBrandColor(hex: String) -> Color { Color(hex: hex) }

private struct AgentIconView: View {
    let agent: String
    let size: CGFloat
    let colorHex: String

    private var color: Color { Color(hex: colorHex) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(color.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                        .strokeBorder(color.opacity(0.38), lineWidth: 1)
                )
            logoMark
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private var logoMark: some View {
        let inner = size * 0.58
        switch agent {
        case "claude":
            // 6 radiating bars (Anthropic asterisk)
            Canvas { ctx, sz in
                let cx = sz.width / 2, cy = sz.height / 2
                let barLen = sz.width * 0.44, barW = sz.width * 0.13
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
            .frame(width: inner, height: inner)

        case "cursor":
            Canvas { ctx, sz in
                let s = sz.width
                var path = Path()
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
            .frame(width: inner, height: inner)

        case "vscode":
            Text("</>")
                .font(.system(size: inner * 0.36, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: inner, height: inner)

        case "copilot_cli":
            Canvas { ctx, sz in
                let s = sz.width, lw = s * 0.11
                var arc = Path()
                arc.addArc(center: CGPoint(x: s / 2, y: s * 0.56),
                           radius: s * 0.36, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                ctx.stroke(arc, with: .color(color), lineWidth: lw)
                ctx.stroke(Path(ellipseIn: CGRect(x: s * 0.10, y: s * 0.45, width: s * 0.30, height: s * 0.30)),
                           with: .color(color), lineWidth: lw)
                ctx.stroke(Path(ellipseIn: CGRect(x: s * 0.60, y: s * 0.45, width: s * 0.30, height: s * 0.30)),
                           with: .color(color), lineWidth: lw)
            }
            .frame(width: inner, height: inner)

        case "windsurf":
            Canvas { ctx, sz in
                let s = sz.width, lw = s * 0.10
                for off: CGFloat in [0, s * 0.22] {
                    var wave = Path()
                    wave.move(to: CGPoint(x: s * 0.05, y: s * 0.38 + off))
                    wave.addCurve(to: CGPoint(x: s * 0.50, y: s * 0.38 + off),
                                  control1: CGPoint(x: s * 0.20, y: s * 0.22 + off),
                                  control2: CGPoint(x: s * 0.35, y: s * 0.54 + off))
                    wave.addCurve(to: CGPoint(x: s * 0.95, y: s * 0.38 + off),
                                  control1: CGPoint(x: s * 0.65, y: s * 0.22 + off),
                                  control2: CGPoint(x: s * 0.80, y: s * 0.54 + off))
                    ctx.stroke(wave, with: .color(color), lineWidth: lw)
                }
            }
            .frame(width: inner, height: inner)

        case "codex_cli":
            Text(">_")
                .font(.system(size: inner * 0.38, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: inner, height: inner)

        default:
            Text(String(agentDisplayName(agent).prefix(1)))
                .font(.system(size: inner * 0.50, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .frame(width: inner, height: inner)
        }
    }
}

// MARK: - Expanded bottom row

@available(iOS 17.0, *)
private struct ExpandedBottomRow: View {
    let state: DoomCoderActivityAttributes.ContentState
    let attributes: DoomCoderActivityAttributes

    var body: some View {
        if state.approvalPending, let rid = state.requestId {
            approvalButtons(rid: rid)
        } else {
            infoRow
        }
    }

    @ViewBuilder
    private func approvalButtons(rid: String) -> some View {
        HStack(spacing: 6) {
            Button(intent: ApproveIntent(requestId: rid, agent: attributes.agent, tool: state.currentTool ?? "")) {
                Label("Approve", systemImage: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .tint(.green)
            Button(intent: DenyIntent(requestId: rid, agent: attributes.agent, tool: state.currentTool ?? "")) {
                Label("Deny", systemImage: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .tint(.red)
            Button(intent: AlwaysAllowIntent(requestId: rid, agent: attributes.agent, tool: state.currentTool ?? "")) {
                Image(systemName: "infinity")
                    .font(.system(size: 11, weight: .semibold))
            }
            .tint(.orange)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
    }

    private var infoRow: some View {
        HStack(spacing: 8) {
            if let tool = state.currentTool {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(tool)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(state.toolCount) tools")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Lock screen / StandBy view

@available(iOS 17.0, *)
struct LockScreenView: View {
    let state: DoomCoderActivityAttributes.ContentState
    let attributes: DoomCoderActivityAttributes

    var agentColor: Color { Color(hex: attributes.agentColorHex) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            if state.approvalPending, let rid = state.requestId {
                approvalSection(rid: rid)
            } else {
                toolRow
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            AgentIconView(agent: attributes.agent, size: 36, colorHex: attributes.agentColorHex)
            VStack(alignment: .leading, spacing: 1) {
                Text(agentDisplayName(attributes.agent))
                    .font(.subheadline.bold())
                Text(attributes.cwdBasename)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 3) {
                    Image(systemName: statusSystemImage(state.status))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(statusColor(state.status))
                    Text(formatElapsed(state.elapsedSec))
                        .font(.system(size: 10).monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func approvalSection(rid: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
            Text("\(state.currentTool ?? "Tool") needs approval")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        HStack(spacing: 8) {
            Button(intent: ApproveIntent(requestId: rid, agent: attributes.agent, tool: state.currentTool ?? "")) {
                Label("Approve", systemImage: "checkmark")
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity)
            }
            .tint(.green)
            Button(intent: DenyIntent(requestId: rid, agent: attributes.agent, tool: state.currentTool ?? "")) {
                Label("Deny", systemImage: "xmark")
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity)
            }
            .tint(.red)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
    }

    private var toolRow: some View {
        HStack(spacing: 6) {
            if let detail = state.toolDetail ?? state.currentTool {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(state.toolCount) tools")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Widget

struct DoomCoderActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DoomCoderActivityAttributes.self) { context in
            LockScreenView(state: context.state, attributes: context.attributes)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .activityBackgroundTint(Color(hex: context.attributes.agentColorHex).opacity(0.12))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    AgentIconView(
                        agent: context.attributes.agent,
                        size: 30,
                        colorHex: context.attributes.agentColorHex
                    )
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(agentDisplayName(context.attributes.agent))
                            .font(.caption.bold())
                        Text(formatElapsed(context.state.elapsedSec))
                            .font(.system(size: 10).monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.toolDetail ?? context.attributes.cwdBasename)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedBottomRow(state: context.state, attributes: context.attributes)
                        .padding(.horizontal, 4)
                }
            } compactLeading: {
                AgentIconView(
                    agent: context.attributes.agent,
                    size: 20,
                    colorHex: context.attributes.agentColorHex
                )
            } compactTrailing: {
                HStack(spacing: 3) {
                    Image(systemName: statusSystemImage(context.state.status))
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(statusColor(context.state.status))
                    Text(formatElapsed(context.state.elapsedSec))
                        .font(.system(size: 10).monospaced())
                        .foregroundStyle(.secondary)
                }
            } minimal: {
                Image(systemName: agentSFSymbol(context.attributes.agent))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(hex: context.attributes.agentColorHex))
            }
            .keylineTint(Color(hex: context.attributes.agentColorHex))
        }
    }
}

@main
@available(iOS 17.0, *)
struct DoomCoderWidgetBundle: WidgetBundle {
    var body: some Widget {
        DoomCoderActivityWidget()
    }
}
