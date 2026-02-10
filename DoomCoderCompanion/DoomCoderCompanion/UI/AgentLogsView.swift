// AgentLogsView.swift — DoomCoder Companion
// Paged list of NotificationLog records for a single agent (last 7 days)

import SwiftUI
import DoomCoderCore

struct AgentLogsView: View {
    let agent: TrackedAgent
    
    @State private var logs: [NotificationLogRecord] = []
    @State private var isLoading = true
    
    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading logs...")
            } else if logs.isEmpty {
                ScrollView {
                    VStack(spacing: 24) {
                        ContentUnavailableView(
                            "No Logs Yet",
                            systemImage: "tray",
                            description: Text("Notifications will appear here")
                        )
                        capabilityFooter
                            .padding(.horizontal)
                    }
                }
            } else {
                List {
                    ForEach(logs, id: \.notifId) { log in
                        LogRow(log: log)
                    }
                    Section {
                        capabilityFooter
                    } header: {
                        Text("Notifications this agent sends")
                    }
                }
            }
        }
        .navigationTitle(agent.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadLogs()
        }
        .refreshable {
            await loadLogs()
        }
    }

    @ViewBuilder
    private var capabilityFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(AgentCapabilityCatalog.capabilities(for: agent)) { cap in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: cap.symbolName)
                        .foregroundStyle(.tint)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(cap.title).font(.callout.weight(.medium))
                        Text(cap.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    private func loadLogs() async {
        isLoading = true
        logs = await NotificationLogStore.shared.fetchLogs(forAgent: agent)
        isLoading = false
    }
}

struct LogRow: View {
    let log: NotificationLogRecord
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(formatTime(log.ts))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                PhasePill(phase: log.phase)
            }
            
            Text(log.title)
                .font(.body.weight(.medium))
            
            if !log.body.isEmpty {
                Text(log.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            
            if let tool = log.lastTool, !tool.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.caption2)
                    Text(tool)
                        .font(.caption2)
                }
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        
        if calendar.isDateInToday(date) {
            formatter.timeStyle = .short
            return formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            formatter.timeStyle = .short
            return "Yesterday " + formatter.string(from: date)
        } else {
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
    }
}

struct PhasePill: View {
    let phase: String
    
    var body: some View {
        Text(displayText)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(backgroundColor)
            .foregroundStyle(foregroundColor)
            .clipShape(Capsule())
    }
    
    private var normalizedPhase: NormalizedEventPhase? {
        NormalizedEventPhase(rawValue: phase)
    }
    
    private var displayText: String {
        guard let p = normalizedPhase else { return phase }
        switch p {
        case .sessionStart: return "Start"
        case .sessionEnd: return "End"
        case .userPrompt: return "Prompt"
        case .toolStart: return "Tool"
        case .toolEnd: return "Done"
        case .toolError: return "Error"
        case .permissionNeeded: return "Permission"
        case .agentResponse: return "Response"
        case .subagentStart: return "Sub-agent"
        case .subagentEnd: return "Sub-end"
        case .error: return "Error"
        case .other: return "Other"
        }
    }
    
    private var backgroundColor: Color {
        guard let p = normalizedPhase else { return .gray.opacity(0.2) }
        switch p.iOSInterruptionLevel {
        case .timeSensitive: return .red.opacity(0.2)
        case .active: return .blue.opacity(0.2)
        case .passive: return .gray.opacity(0.2)
        case .critical: return .red.opacity(0.3)
        }
    }
    
    private var foregroundColor: Color {
        guard let p = normalizedPhase else { return .secondary }
        switch p.iOSInterruptionLevel {
        case .timeSensitive: return .red
        case .active: return .blue
        case .passive: return .secondary
        case .critical: return .red
        }
    }
}
