// AgentLogsView.swift — DoomCoder Companion
// Per-agent view: capability card at top, full-height notification log below.

import SwiftUI
import DoomCoderCore

struct AgentLogsView: View {
    let agent: TrackedAgent

    @State private var logs: [NotificationLogRecord] = []
    @State private var isLoading = true
    @State private var showClearConfirm = false

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 20) {
                capabilityCard
                notificationTray
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(agent.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadLogs() }
        .refreshable {
            await loadLogs()
            await CompanionSyncEngine.shared.fetchChanges()
        }
        .alert("Clear notifications for \(agent.displayName)?", isPresented: $showClearConfirm) {
            Button("Clear", role: .destructive) { clearLogs() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all notification history for this agent on this device.")
        }
    }

    // MARK: - Capability card

    private var capabilityCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What this agent delivers")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            let caps = AgentCapabilityCatalog.capabilities(for: agent)
            if caps.isEmpty {
                Text("No capability info available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(caps) { cap in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: cap.symbolName)
                            .foregroundStyle(.tint)
                            .frame(width: 20)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cap.title).font(.callout.weight(.medium))
                            Text(cap.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Notification tray

    private var notificationTray: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Notification Activity")
                    .font(.headline)
                Text("(\(logs.count))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if !logs.isEmpty {
                    Button("Clear All") { showClearConfirm = true }
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                        .padding(.vertical, 32)
                    Spacer()
                }
            } else if logs.isEmpty {
                ContentUnavailableView(
                    "No Activity Yet",
                    systemImage: "tray",
                    description: Text("Notifications for \(agent.displayName) will appear here.")
                )
                .padding(.vertical, 24)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(logs, id: \.notifId) { log in
                        LogRow(log: log)
                            .padding(.horizontal, 20)
                        Divider()
                            .padding(.leading, 20)
                    }
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Actions

    private func loadLogs() async {
        isLoading = true
        logs = await NotificationLogStore.shared.fetchLogs(forAgent: agent)
        isLoading = false
    }

    private func clearLogs() {
        NotificationLogStore.shared.clear(forAgent: agent)
        logs = []
    }
}

// MARK: - LogRow

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
                        .accessibilityHidden(true)
                    Text(tool)
                        .font(.caption2)
                }
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 12)
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

// MARK: - PhasePill

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
        case .timeSensitive: return .red.opacity(0.15)
        case .active: return Color.accentColor.opacity(0.15)
        case .passive: return .gray.opacity(0.15)
        case .critical: return .red.opacity(0.2)
        }
    }

    private var foregroundColor: Color {
        guard let p = normalizedPhase else { return .secondary }
        switch p.iOSInterruptionLevel {
        case .timeSensitive: return .red
        case .active: return Color.accentColor
        case .passive: return .secondary
        case .critical: return .red
        }
    }
}
