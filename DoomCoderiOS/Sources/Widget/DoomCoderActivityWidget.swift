import ActivityKit
import SwiftUI
import WidgetKit

@available(iOS 17.0, *)
struct DoomCoderActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DoomCoderActivityAttributes.self) { context in
            LockScreenView(state: context.state, attributes: context.attributes)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(statusEmoji(context.state.status))
                        .font(.title2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.agent.capitalized)
                        .font(.caption.bold())
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.cwdBasename)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    bottomContent(state: context.state, attributes: context.attributes)
                }
            } compactLeading: {
                Text(statusEmoji(context.state.status))
            } compactTrailing: {
                Text(context.state.currentTool ?? "")
                    .font(.caption2)
                    .lineLimit(1)
            } minimal: {
                Text(statusEmoji(context.state.status))
            }
            .keylineTint(.orange)
        }
    }

    @ViewBuilder
    private func bottomContent(state: DoomCoderActivityAttributes.ContentState,
                               attributes: DoomCoderActivityAttributes) -> some View {
        if state.status == "waitingApproval", let rid = state.requestId {
            HStack(spacing: 8) {
                Button(intent: ApproveIntent(requestId: rid, agent: attributes.agent, tool: state.currentTool ?? "")) {
                    Text("Approve").font(.caption.bold())
                }
                .tint(.green)
                Button(intent: DenyIntent(requestId: rid, agent: attributes.agent, tool: state.currentTool ?? "")) {
                    Text("Deny").font(.caption.bold())
                }
                .tint(.red)
                Button(intent: AlwaysAllowIntent(requestId: rid, agent: attributes.agent, tool: state.currentTool ?? "")) {
                    Text("Always").font(.caption.bold())
                }
                .tint(.orange)
            }
            .buttonStyle(.borderedProminent)
        } else {
            HStack {
                Text("\(state.toolCount) tools").font(.caption2)
                Spacer()
                if let t = state.currentTool { Text(t).font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }

    private func statusEmoji(_ s: String) -> String {
        switch s {
        case "running": return "🟢"
        case "waitingApproval": return "🟠"
        case "failed": return "🔴"
        case "completed": return "✅"
        default: return "⚫"
        }
    }
}

@available(iOS 17.0, *)
struct LockScreenView: View {
    let state: DoomCoderActivityAttributes.ContentState
    let attributes: DoomCoderActivityAttributes

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(statusEmoji(state.status)).font(.title3)
                Text("\(attributes.agent.capitalized) · \(attributes.cwdBasename)").font(.callout.bold())
                Spacer()
            }
            if state.status == "waitingApproval", let rid = state.requestId {
                Text("⚠ \(state.currentTool ?? "tool") pending").font(.caption).foregroundStyle(.orange)
                HStack {
                    Button(intent: ApproveIntent(requestId: rid, agent: attributes.agent, tool: state.currentTool ?? "")) {
                        Text("Approve")
                    }.tint(.green)
                    Button(intent: DenyIntent(requestId: rid, agent: attributes.agent, tool: state.currentTool ?? "")) {
                        Text("Deny")
                    }.tint(.red)
                }
                .buttonStyle(.borderedProminent)
                .font(.caption.bold())
            } else {
                Text("\(state.currentTool ?? "—") · \(state.toolCount) tools")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusEmoji(_ s: String) -> String {
        switch s {
        case "running": return "🟢"
        case "waitingApproval": return "🟠"
        case "failed": return "🔴"
        case "completed": return "✅"
        default: return "⚫"
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
