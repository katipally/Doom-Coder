// DoomCoderWidgetLiveActivity.swift — DoomCoder Widget Extension
// Live Activity and Dynamic Island views for active coding sessions.
// Reads DoomCoderActivityAttributes (from DoomCoderCore) pushed by
// LiveActivityManager in the iOS companion app.

import ActivityKit
import WidgetKit
import SwiftUI
import DoomCoderCore

// MARK: - Live Activity Widget

@available(iOS 16.1, *)
struct DoomCoderWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DoomCoderActivityAttributes.self) { context in
            // Lock screen / notification banner UI
            LockScreenView(context: context)
                .activityBackgroundTint(Color(.systemBackground))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded (long-press)
                DynamicIslandExpandedRegion(.leading) {
                    ExpandedLeading(context: context)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ExpandedTrailing(context: context)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedBottom(context: context)
                }
            } compactLeading: {
                CompactLeadingView(agent: context.attributes.agent)
            } compactTrailing: {
                CompactTrailingView(context: context)
            } minimal: {
                MinimalView(agent: context.attributes.agent)
            }
            .widgetURL(URL(string: "doomcoder://session/\(context.attributes.sessionKey)"))
            .keylineTint(context.state.awaitingPermission ? .orange : .green)
        }
    }
}

// MARK: - Lock screen view

private struct LockScreenView: View {
    let context: ActivityViewContext<DoomCoderActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            AgentSymbol(agent: context.attributes.agent, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(context.state.agentDisplayName)
                        .font(.headline)
                    Spacer()
                    Text(elapsedText(context.state.elapsedSeconds))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(context.state.displayState)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let tool = context.state.lastTool {
                    Text(tool)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            if context.state.awaitingPermission {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Dynamic Island: expanded regions

private struct ExpandedLeading: View {
    let context: ActivityViewContext<DoomCoderActivityAttributes>
    var body: some View {
        HStack(spacing: 8) {
            AgentSymbol(agent: context.attributes.agent, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(context.state.agentDisplayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if let base = context.state.cwdBase {
                    Text(base)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.leading, 4)
    }
}

private struct ExpandedTrailing: View {
    let context: ActivityViewContext<DoomCoderActivityAttributes>
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(elapsedText(context.state.elapsedSeconds))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)
            Text("\(context.state.toolCallCount) calls")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.trailing, 4)
    }
}

private struct ExpandedBottom: View {
    let context: ActivityViewContext<DoomCoderActivityAttributes>
    var body: some View {
        HStack {
            if context.state.awaitingPermission {
                Label("Needs your approval", systemImage: "hand.raised.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            } else if let tool = context.state.lastTool {
                Label(tool, systemImage: "wrench.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(context.state.displayState)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }
}

// MARK: - Dynamic Island: compact + minimal

private struct CompactLeadingView: View {
    let agent: String
    var body: some View {
        AgentSymbol(agent: agent, size: 20)
    }
}

private struct CompactTrailingView: View {
    let context: ActivityViewContext<DoomCoderActivityAttributes>
    var body: some View {
        if context.state.awaitingPermission {
            Label("Wait", systemImage: "hand.raised.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.orange)
                .font(.caption2.weight(.bold))
        } else {
            Text(elapsedText(context.state.elapsedSeconds))
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.green)
        }
    }
}

private struct MinimalView: View {
    let agent: String
    var body: some View {
        AgentSymbol(agent: agent, size: 16)
    }
}

// MARK: - Agent icon (SF Symbol fallback — bundle assets not available in widget)

private struct AgentSymbol: View {
    let agent: String
    let size: CGFloat

    private var symbolName: String {
        switch agent {
        case "claude":     return "c.circle.fill"
        case "cursor":     return "cursorarrow.rays"
        case "vscode":     return "chevron.left.forwardslash.chevron.right"
        case "copilotCLI": return "terminal.fill"
        case "windsurf":   return "wind"
        case "codexCLI":   return "circle.hexagongrid.fill"
        default:           return "cpu.fill"
        }
    }

    var body: some View {
        Image(systemName: symbolName)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(.green)
    }
}

// MARK: - Helpers

private func elapsedText(_ seconds: Int) -> String {
    if seconds < 3600 {
        let m = seconds / 60, s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
    let h = seconds / 3600, m = (seconds % 3600) / 60
    return String(format: "%dh%02dm", h, m)
}
