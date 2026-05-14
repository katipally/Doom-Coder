import SwiftUI

// Side panel that slides in when a node is tapped on the session map.
// Shows event metadata, phase, tool, and raw payload.

struct NodeDetailPanel: View {
    let event: MapEventNode
    var onClose: () -> Void

    @State private var payloadExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Circle()
                    .fill(phaseColor(event.phase))
                    .frame(width: 8, height: 8)
                Text(event.event)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().opacity(0.15)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    row(label: "Phase",     value: event.phase.rawValue)
                    row(label: "Time",      value: formattedTime(event.timestamp))
                    if let tool = event.tool {
                        row(label: "Tool", value: tool)
                    }
                    if !event.summary.isEmpty {
                        row(label: "Summary", value: event.summary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                payloadExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text("Raw Payload")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Image(systemName: payloadExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)

                        if payloadExpanded {
                            if let payload = event.rawPayload, !payload.isEmpty {
                                Text(prettyJSON(payload))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.white.opacity(0.04),
                                                in: RoundedRectangle(cornerRadius: 6))
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            } else {
                                Text("Payload not captured for this event.")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.white.opacity(0.02),
                                                in: RoundedRectangle(cornerRadius: 6))
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
        .background(Color(NSColor.windowBackgroundColor).opacity(0.95))
        .overlay(
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(width: 0.5),
            alignment: .leading
        )
    }

    // MARK: - Helpers

    @ViewBuilder
    private func row(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11.5))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }

    private func formattedTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: date)
    }

    private func prettyJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
              let str = String(data: pretty, encoding: .utf8)
        else { return raw }
        return str
    }

    private func phaseColor(_ phase: NormalizedEventPhase) -> Color {
        switch phase {
        case .toolError, .error:    return .red
        case .permissionNeeded:     return .orange
        case .sessionEnd:           return .green
        case .toolStart:            return .blue
        case .toolEnd:              return .green.opacity(0.7)
        case .agentResponse:        return .purple
        case .userPrompt:           return .yellow
        default:                    return .white.opacity(0.4)
        }
    }
}
