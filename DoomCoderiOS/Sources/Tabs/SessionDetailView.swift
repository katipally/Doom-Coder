import SwiftUI

// MARK: - EventDetailSheet

private struct EventDetailSheet: View {
    let event: CKAgentEvent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let toolName = event.toolName {
                        Label(toolName, systemImage: "wrench.and.screwdriver.fill")
                            .font(.headline)
                    }
                    if let filePath = event.filePath {
                        Label(filePath, systemImage: "doc.fill")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    Text(event.payloadJSON)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding()
            }
            .background(Color(white: 0.08).ignoresSafeArea())
            .navigationTitle(event.hookPhase.capitalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - SessionDetailView

struct SessionDetailView: View {
    let sessionKey: String
    @State private var aggregate: CKSessionAggregate?
    @State private var events: [CKAgentEvent] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var selectedEvent: CKAgentEvent?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let agg = aggregate { header(agg) }
                stats
                timeline
            }
            .padding()
        }
        .background(LinearGradient(colors: [Color(white: 0.06), Color(white: 0.02)],
                                   startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .navigationTitle(aggregate?.cwdBasename ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { copyJSON() } label: { Image(systemName: "doc.on.doc") }
            }
        }
        .task { await load() }
        .sheet(item: $selectedEvent) { EventDetailSheet(event: $0) }
    }

    private func header(_ agg: CKSessionAggregate) -> some View {
        HStack(spacing: 12) {
            AgentBrandIcon(agent: agg.agent, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: statusSystemImage(agg.status))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(statusColor(agg.status))
                    Text(agentDisplayName(agg.agent))
                        .font(.title3.bold())
                }
                Text(agg.cwdBasename).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder private var stats: some View {
        if let agg = aggregate {
            VStack(alignment: .leading, spacing: 6) {
                if let model = agg.model { statRow("Model", model, systemImage: "cpu") }
                statRow("Tools used", "\(agg.totalToolCalls)", systemImage: "wrench.and.screwdriver")
                statRow("Files edited", "\(agg.totalFilesEdited)", systemImage: "doc.badge.plus")
                statRow("Errors", "\(agg.totalErrors)", systemImage: "exclamationmark.triangle")
                statRow("Started", agg.startedAt.formatted(date: .abbreviated, time: .standard), systemImage: "calendar.clock")
                if let ended = agg.endedAt {
                    let s = Int(ended.timeIntervalSince(agg.startedAt))
                    statRow("Duration", "\(s / 60)m \(s % 60)s", systemImage: "timer")
                }
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func statRow(_ k: String, _ v: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.callout)
        }
    }

    @ViewBuilder private var timeline: some View {
        if loading {
            ProgressView().padding().frame(maxWidth: .infinity)
        } else if let err = loadError {
            Label("Error: \(err)", systemImage: "exclamationmark.circle").foregroundStyle(.red)
        } else if events.isEmpty {
            Label("No events recorded", systemImage: "clock").foregroundStyle(.secondary).padding()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Timeline").font(.headline).padding(.bottom, 4)
                ForEach(events) { e in
                    Button {
                        selectedEvent = e
                    } label: {
                        HStack(alignment: .center, spacing: 10) {
                            let (sym, col) = phaseGlyph(e.hookPhase)
                            Image(systemName: sym)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(col)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.hookPhase.capitalized)
                                    .font(.caption.bold())
                                if let tool = e.toolName {
                                    Text(tool)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                if let path = e.filePath {
                                    Text(path)
                                        .font(.system(size: 10).monospaced())
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Text(e.occurredAt.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 9).monospaced())
                                .foregroundStyle(.quaternary)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(.white.opacity(0.05))
                            .frame(height: 1)
                    }
                }
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func phaseGlyph(_ phase: String) -> (String, Color) {
        switch phase.lowercased() {
        case "sessionstart":           return ("play.circle.fill", .green)
        case "sessionstop", "sessionend": return ("stop.circle.fill", .gray)
        case "userprompt":             return ("message.fill", .blue)
        case "pretool", "pretooluse":  return ("hammer.fill", .orange)
        case "posttool", "posttooluse": return ("checkmark.circle.fill", .teal)
        default:                       return ("circle", .secondary)
        }
    }

    private func agentSFSymbol(_ agent: String) -> String { AgentBrand(rawAgent: agent).sfSymbolName }
    private func agentDisplayName(_ agent: String) -> String { AgentBrand(rawAgent: agent).fullDisplayName }
    private func agentBrandColor(_ agent: String) -> Color { AgentBrand(rawAgent: agent).primaryColor }

    private func statusSystemImage(_ s: CKSessionAggregate.Status) -> String {
        switch s {
        case .running:         return "circle.fill"
        case .waitingApproval: return "exclamationmark.circle.fill"
        case .completed:       return "checkmark.circle.fill"
        case .failed:          return "xmark.circle.fill"
        }
    }

    private func statusColor(_ s: CKSessionAggregate.Status) -> Color {
        switch s {
        case .running:         return .green
        case .waitingApproval: return .orange
        case .completed:       return .gray
        case .failed:          return .red
        }
    }

    private func load() async {
        loading = true
        do {
            aggregate = try await CloudKitClient.shared.fetchAggregate(sessionKey: sessionKey)
            events = try await CloudKitClient.shared.fetchEvents(sessionKey: sessionKey)
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
    }

    private func copyJSON() {
        guard let agg = aggregate else { return }
        let dict: [String: Any] = [
            "sessionKey": agg.sessionKey,
            "agent": agg.agent,
            "cwdBasename": agg.cwdBasename,
            "status": agg.status.rawValue,
            "totalToolCalls": agg.totalToolCalls,
            "totalFilesEdited": agg.totalFilesEdited,
            "events": events.map { ["phase": $0.hookPhase, "at": $0.occurredAt.timeIntervalSince1970] }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8) {
            UIPasteboard.general.string = str
        }
    }
}

// MARK: - CKAgentEvent Identifiable

extension CKAgentEvent: Identifiable {
    public var id: String { recordName }
}
